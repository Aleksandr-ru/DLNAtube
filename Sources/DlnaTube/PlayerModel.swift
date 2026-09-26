import Foundation
import SwiftUI

struct PlaybackTimeline {
    private(set) var position: Double = 0
    private(set) var playing = false
    private var anchorUptime: TimeInterval = 0

    mutating func reset(position: Double, playing: Bool, uptime: TimeInterval) {
        self.position = max(0, position)
        self.playing = playing
        anchorUptime = uptime
    }

    func estimatedPosition(at uptime: TimeInterval, duration: Double) -> Double {
        let elapsed = playing ? max(0, uptime - anchorUptime) : 0
        let estimate = position + elapsed
        return duration > 0 ? min(duration, estimate) : estimate
    }

    mutating func reconcile(reportedPosition: Double?, remotePlaying: Bool,
                            uptime: TimeInterval, duration: Double,
                            keepClockMoving: Bool) -> Double {
        let estimate = estimatedPosition(at: uptime, duration: duration)
        let validReport = reportedPosition.flatMap { $0 > 0 ? $0 : nil }
        let resolved: Double
        if keepClockMoving {
            resolved = max(estimate, validReport ?? 0)
        } else {
            resolved = validReport ?? estimate
        }
        reset(position: duration > 0 ? min(duration, resolved) : resolved,
              playing: remotePlaying, uptime: uptime)
        return position
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var devices: [Renderer] = []
    @Published var selectedDeviceID = ""
    @Published var capabilities: RendererCapabilities?
    @Published var capabilityMessage: String?
    @Published var loadingCapabilities = false
    @Published var videoURL = ""
    @Published private(set) var videoHistory: [VideoHistoryEntry]
    @Published private(set) var desiredQuality: VideoQuality = .p720
    @Published var proxyURL = UserDefaults.standard.string(forKey: ProxySettings.preferenceKey) ?? ProxySettings.defaultURL
    @Published private(set) var language = AppLanguage.current
    @Published var title = ""
    @Published var status = L10n.text("Готово", "Ready")
    @Published var errorMessage: String?
    @Published var discovering = false
    @Published var busy = false
    @Published var preparing = false
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var canSeek = false
    @Published var hasMedia = false

    private var server: MediaServer?
    private var activeDevice: Renderer?
    private var pendingDevice: Renderer?
    private var currentSource: MediaSource?
    private var currentProxy: String?
    private var playbackBase: Double = 0
    private var playbackTimeline = PlaybackTimeline()
    private var pollTask: Task<Void, Never>?
    private var castTask: Task<Void, Never>?
    private var capabilityTask: Task<Void, Never>?
    private var capabilityDeviceID = ""
    private var capabilityCache: [String: RendererCapabilities] = [:]
    private var lastPollingError: String?
    private var qualityByDevice: [String: VideoQuality] = [:]

    init() {
        let defaults = UserDefaults.standard
        let oldPreferences = defaults.persistentDomain(forName: "app.dlnatube.DlnaTube") ?? [:]
        for key in [ProxySettings.preferenceKey, AppLanguage.preferenceKey, "videoHistory", VideoQuality.preferencesByDeviceKey]
            where defaults.object(forKey: key) == nil {
            if let value = oldPreferences[key] { defaults.set(value, forKey: key) }
        }
        let stored = defaults.data(forKey: "videoHistory")
        let entries = stored.flatMap { try? JSONDecoder().decode([VideoHistoryEntry].self, from: $0) } ?? []
        var seen = Set<String>()
        videoHistory = entries.filter { !$0.url.isEmpty && seen.insert($0.url).inserted }.prefix(100).map { $0 }
        proxyURL = defaults.string(forKey: ProxySettings.preferenceKey) ?? ProxySettings.defaultURL
        language = AppLanguage.current
        status = L10n.text("Готово", "Ready")
        if let data = defaults.data(forKey: VideoQuality.preferencesByDeviceKey),
           let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
            qualityByDevice = stored.reduce(into: [:]) { result, item in
                if let quality = VideoQuality(rawValue: item.value) { result[item.key] = quality }
            }
        }
    }

    func discover(startup: Bool = false) {
        guard !discovering else { return }
        discovering = true
        status = L10n.text("Поиск устройств…", "Searching for devices…")
        errorMessage = nil
        Task {
            var result: [Renderer] = []
            for attempt in 0..<(startup ? 3 : 1) {
                if attempt > 0 {
                    status = L10n.text("Повторный поиск устройств…", "Searching for devices again…")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                result = await SSDP.discover()
                if !result.isEmpty { break }
            }
            devices = result
            discovering = false
            if !result.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = result.count == 1 ? result[0].id : ""
            }
            loadCapabilities()
            status = result.isEmpty
                ? L10n.text(
                    "DLNA-устройства не найдены. Проверьте сеть и разрешение «Локальная сеть» для DLNAtube в настройках macOS.",
                    "No DLNA devices found. Check the network and the Local Network permission for DLNAtube in macOS Settings."
                )
                : L10n.text("Найдено устройств: \(result.count)", "Devices found: \(result.count)")
        }
    }

    func loadCapabilities() {
        guard let device = devices.first(where: { $0.id == selectedDeviceID }) else {
            capabilityTask?.cancel()
            capabilityDeviceID = ""
            capabilities = nil
            capabilityMessage = nil
            loadingCapabilities = false
            desiredQuality = .p720
            return
        }
        if loadingCapabilities && capabilityDeviceID == device.id { return }
        capabilityTask?.cancel()
        capabilityDeviceID = device.id
        desiredQuality = qualityByDevice[device.id] ?? .p720
        capabilities = capabilityCache[device.id]
        capabilityMessage = nil
        guard capabilities == nil else {
            applyRecommendedQuality()
            loadingCapabilities = false
            return
        }
        loadingCapabilities = true
        capabilityTask = Task {
            do {
                let value = try await DLNA.capabilities(device: device)
                guard !Task.isCancelled, selectedDeviceID == device.id else { return }
                capabilityCache[device.id] = value
                capabilities = value
                applyRecommendedQuality()
            } catch {
                guard !Task.isCancelled, selectedDeviceID == device.id else { return }
                capabilityMessage = error.localizedDescription
            }
            loadingCapabilities = false
            capabilityTask = nil
        }
    }

    func selectVideoQuality(_ quality: VideoQuality) {
        desiredQuality = quality
        guard !selectedDeviceID.isEmpty else { return }
        qualityByDevice[selectedDeviceID] = quality
        let stored = qualityByDevice.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: VideoQuality.preferencesByDeviceKey)
        }
    }

    private func applyRecommendedQuality() {
        if let saved = qualityByDevice[selectedDeviceID] {
            desiredQuality = saved
            return
        }
        desiredQuality = VideoQuality.recommended(maxHeight: capabilities?.maxVideoHeight)
    }

    @discardableResult
    func saveSettings(proxy: String, language newLanguage: AppLanguage) -> Bool {
        do {
            let normalized = try ProxySettings.normalized(proxy)
            UserDefaults.standard.set(normalized ?? "", forKey: ProxySettings.preferenceKey)
            UserDefaults.standard.set(newLanguage.rawValue, forKey: AppLanguage.preferenceKey)
            proxyURL = normalized ?? ""
            language = newLanguage
            errorMessage = nil
            status = L10n.text("Настройки сохранены", "Settings saved")
            return true
        } catch {
            show(error)
            return false
        }
    }

    func cast() {
        guard !busy, let device = devices.first(where: { $0.id == selectedDeviceID }) else { return }
        let requestedURL = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedURL.isEmpty else { return }
        busy = true
        preparing = true
        errorMessage = nil
        status = L10n.text("Получение видеопотока…", "Retrieving the video stream…")
        pendingDevice = device
        castTask = Task {
            do {
                let proxy = try ProxySettings.normalized(proxyURL)
                let source = try await MediaExtractor.extract(
                    videoURL: requestedURL,
                    proxy: proxy,
                    maxVideoHeight: desiredQuality.rawValue
                ) { [weak self] message in
                    Task { @MainActor [weak self] in
                        if self?.preparing == true { self?.status = message }
                    }
                }
                if source.isTransportStream { try MediaBridge.requireAvailable() }
                try Task.checkCancellation()
                if server == nil { server = try MediaServer() }
                guard let server else { return }
                pollTask?.cancel()
                if let previous = activeDevice {
                    _ = try? await DLNA.command("Stop", device: previous)
                }
                server.set(source, proxy: proxy)
                let localURL = try server.url(for: device)
                status = L10n.text("Подключение к телевизору…", "Connecting to the TV…")
                try Task.checkCancellation()
                try await DLNA.setMedia(localURL, title: source.title, device: device, isTransportStream: source.isTransportStream)
                try Task.checkCancellation()
                _ = try await DLNA.command("Play", device: device, arguments: [("Speed", "1")])
                StreamingLog.dlna.info("Playback started: device=\(device.name, privacy: .public), transport=\(source.isTransportStream ? "mpeg-ts" : "mp4", privacy: .public)")
                recordSuccessfulPlayback(url: requestedURL, title: source.title)
                activeDevice = device
                currentSource = source
                currentProxy = proxy
                playbackBase = 0
                title = source.title
                playing = true
                position = 0
                duration = source.duration ?? 0
                playbackTimeline.reset(position: 0, playing: true,
                                       uptime: ProcessInfo.processInfo.systemUptime)
                canSeek = duration > 0
                hasMedia = true
                status = playbackStatus(playing: true, deviceName: device.name, source: source)
                startPolling()
            } catch is CancellationError {
                status = L10n.text("Подготовка отменена", "Preparation cancelled")
                errorMessage = nil
            } catch { show(error) }
            busy = false
            preparing = false
            castTask = nil
            pendingDevice = nil
        }
    }

    func stopBeforeApplicationExit() async {
        pollTask?.cancel()
        capabilityTask?.cancel()

        let castInProgress = castTask
        let castDevice = pendingDevice
        castInProgress?.cancel()
        if let castInProgress { await castInProgress.value }

        var targets = [Renderer]()
        if let activeDevice { targets.append(activeDevice) }
        if let castDevice, !targets.contains(where: { $0.id == castDevice.id }) {
            targets.append(castDevice)
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for device in targets {
                group.addTask {
                    _ = try? await DLNA.command("Stop", device: device, timeout: 2)
                }
            }
            await group.waitForAll()
        }
    }

    func cancelPreparation() {
        guard preparing else { return }
        castTask?.cancel()
        status = L10n.text("Отмена подготовки…", "Cancelling preparation…")
    }

    func togglePlayback() {
        guard let device = activeDevice, !busy else { return }
        let wasPlaying = playing
        busy = true
        Task {
            do {
                if wasPlaying {
                    _ = try await DLNA.command("Pause", device: device)
                } else {
                    _ = try await DLNA.resumePlayback(device: device)
                }
                playing = !wasPlaying
                position = playbackTimeline.estimatedPosition(
                    at: ProcessInfo.processInfo.systemUptime, duration: duration
                )
                playbackTimeline.reset(position: position, playing: playing,
                                       uptime: ProcessInfo.processInfo.systemUptime)
                status = playbackStatus(playing: playing)
                errorMessage = nil
                startPolling()
            } catch { show(error) }
            busy = false
        }
    }

    func stop() {
        guard let device = activeDevice, !busy else { return }
        busy = true
        pollTask?.cancel()
        Task {
            do {
                _ = try await DLNA.command("Stop", device: device)
                applyStoppedState()
                errorMessage = nil
            } catch { show(error) }
            busy = false
        }
    }

    func seek(to seconds: Double) {
        guard let device = activeDevice, let source = currentSource,
              canSeek, !busy, seconds.isFinite else { return }
        let target = min(max(0, seconds), max(0, duration - 1))
        busy = true
        pollTask?.cancel()
        status = L10n.text("Перемотка на \(DLNA.clock(target))…", "Seeking to \(DLNA.clock(target))…")
        Task {
            var succeeded = false
            do {
                if source.isTransportStream {
                    guard let server else {
                        throw TubeError.message(L10n.text(
                            "Локальный медиасервер недоступен.",
                            "The local media server is unavailable."
                        ))
                    }
                    let wasPlaying = playing
                    _ = try? await DLNA.command("Stop", device: device)
                    server.set(source, proxy: currentProxy, startSeconds: target)
                    let url = try server.url(for: device)
                    try await DLNA.setMedia(url, title: source.title, device: device, isTransportStream: true)
                    _ = try await DLNA.resumePlayback(device: device)
                    playing = true
                    if !wasPlaying, (try? await DLNA.command("Pause", device: device)) != nil {
                        playing = false
                    }
                    playbackBase = server.playbackStart()
                } else {
                    _ = try await DLNA.command("Seek", device: device, arguments: [
                        ("Unit", "REL_TIME"), ("Target", DLNA.clock(target))
                    ])
                }
                position = target
                playbackTimeline.reset(position: target, playing: playing,
                                       uptime: ProcessInfo.processInfo.systemUptime)
                errorMessage = nil
                status = playbackStatus(playing: playing)
                succeeded = true
            } catch {
                playing = false
                playbackBase = 0
                show(error)
            }
            busy = false
            if succeeded { startPolling() }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if let device = activeDevice {
                    do {
                        let state = try await DLNA.state(device: device)
                        if lastPollingError != nil {
                            StreamingLog.dlna.info("DLNA polling recovered: device=\(device.name, privacy: .public)")
                            lastPollingError = nil
                        }
                        let wasPlaying = playing
                        let resolvedPlaying = state.resolvedPlaying(previous: wasPlaying)
                        if wasPlaying && !resolvedPlaying {
                            StreamingLog.dlna.error("TV left PLAYING state: device=\(device.name, privacy: .public), state=\(state.name, privacy: .public), position=\(state.position, format: .fixed(precision: 3)), duration=\(state.duration, format: .fixed(precision: 3))")
                        }
                        let transportStream = currentSource?.isTransportStream == true
                        if transportStream, let server {
                            playbackBase = server.playbackStart()
                        }
                        if duration <= 0, state.duration > 0 {
                            duration = transportStream ? playbackBase + state.duration : state.duration
                            canSeek = duration > 0
                        }
                        let absoluteReport = state.position > 0
                            ? max(0, (transportStream ? playbackBase : 0) + state.position)
                            : nil
                        let uptime = ProcessInfo.processInfo.systemUptime
                        position = playbackTimeline.reconcile(
                            reportedPosition: absoluteReport,
                            remotePlaying: resolvedPlaying,
                            uptime: uptime,
                            duration: duration,
                            keepClockMoving: transportStream
                        )
                        let streamFinished = transportStream && server?.playbackCompleted() == true
                        let nearEnd = duration > 0 && position >= max(0, duration - 5)
                        let finished = duration > 0 && (
                            (position >= duration && streamFinished) ||
                            (state.name == "STOPPED" && (streamFinished || nearEnd))
                        )
                        if finished {
                            applyStoppedState(uptime: uptime)
                            return
                        }
                        playing = resolvedPlaying
                        if wasPlaying != playing {
                            status = state.name == "STOPPED"
                                ? L10n.text("Остановлено", "Stopped")
                                : playbackStatus(playing: playing)
                        }
                    } catch {
                        let message = error.localizedDescription
                        if lastPollingError != message {
                            StreamingLog.dlna.error("DLNA polling failed: device=\(device.name, privacy: .public), error=\(message, privacy: .public)")
                            lastPollingError = message
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func recordSuccessfulPlayback(url: String, title: String) {
        let entry = VideoHistoryEntry(url: url, title: title)
        videoHistory.removeAll { $0.url == url }
        videoHistory.insert(entry, at: 0)
        videoHistory = Array(videoHistory.prefix(100))
        if let data = try? JSONEncoder().encode(videoHistory) {
            UserDefaults.standard.set(data, forKey: "videoHistory")
        }
    }

    private func playbackStatus(playing: Bool, deviceName: String? = nil,
                                source: MediaSource? = nil) -> String {
        var text = playing ? L10n.text("Воспроизведение", "Playing") : L10n.text("Пауза", "Paused")
        if let deviceName { text += L10n.text(" на \(deviceName)", " on \(deviceName)") }
        if let height = (source ?? currentSource)?.videoHeight {
            text += " • \(VideoQuality.title(for: height))"
        }
        return text
    }

    private func applyStoppedState(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        playing = false
        playbackBase = 0
        position = 0
        playbackTimeline.reset(position: 0, playing: false, uptime: uptime)
        status = L10n.text("Остановлено", "Stopped")
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription
    }
}
