import XCTest
import YouTubeKit
@testable import DLNAtube

final class DlnaTubeTests: XCTestCase {
    private var appProxy: String {
        let appDefaults = UserDefaults(suiteName: ProxySettings.preferencesDomain)
        return appDefaults?.string(forKey: ProxySettings.preferenceKey) ?? ProxySettings.defaultURL
    }

    func testEscapingAndTime() {
        XCTAssertEqual(XMLTools.escape("A&B <C>"), "A&amp;B &lt;C&gt;")
        XCTAssertEqual(DLNA.seconds("01:02:03"), 3723)
        XCTAssertEqual(DLNA.clock(3723), "01:02:03")
    }

    func testProxyValidation() throws {
        XCTAssertEqual(try ProxySettings.normalized(" socks5://127.0.0.1:1080 "), "socks5://127.0.0.1:1080")
        XCTAssertThrowsError(try ProxySettings.normalized("socks5://localhost"))
    }

    func testRendererCapabilitySummary() {
        let info = [
            "http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_MP_HD_720p_AAC",
            "http-get:*:video/mpeg:DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO",
            "http-get:*:audio/mpeg:DLNA.ORG_PN=MP3",
            "http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG"
        ].joined(separator: ",")
        let capabilities = RendererCapabilities(protocolInfo: info)
        XCTAssertEqual(capabilities.videoFormats, ["MP4", "MPEG-TS"])
        XCTAssertEqual(capabilities.audioFormats, ["AAC", "MP3"])
        XCTAssertEqual(capabilities.resolutionText(language: .russian), "Указан профиль 720p")
        XCTAssertEqual(capabilities.resolutionText(language: .english), "Reported 720p profile")
        XCTAssertEqual(capabilities.maxVideoHeight, 720)
        XCTAssertEqual(
            RendererCapabilities(protocolInfo: "http-get:*:video/mp4:*").resolutionText(language: .russian),
            "Не указано устройством"
        )
        XCTAssertNil(RendererCapabilities(protocolInfo: "http-get:*:video/mp4:*").maxVideoHeight)
        XCTAssertEqual(VideoQuality.recommended(maxHeight: 1080), .p1080)
        XCTAssertEqual(VideoQuality.recommended(maxHeight: 4320), .p4320)
        XCTAssertEqual(VideoQuality.p1440.title, "1440p (2K)")
        XCTAssertEqual(VideoQuality.p2160.title, "2160p (4K)")
        XCTAssertEqual(VideoQuality.p4320.title, "4320p (8K)")
        XCTAssertEqual(VideoQuality.title(for: 720), "720p")
        XCTAssertEqual(VideoQuality.recommended(maxHeight: 600), .p480)
        XCTAssertEqual(VideoQuality.recommended(maxHeight: nil), .p720)
        XCTAssertEqual(MediaExtractor.preferredHeight([360, 720, 1080], maxHeight: 720), 720)
        XCTAssertEqual(MediaExtractor.preferredHeight([360, 1080], maxHeight: 720), 360)
        XCTAssertEqual(MediaExtractor.preferredHeight([1080, 2160], maxHeight: 720), 1080)
    }

    func testInterfaceLocalization() {
        XCTAssertEqual(L10n.text("Русский", "English", language: .russian), "Русский")
        XCTAssertEqual(L10n.text("Русский", "English", language: .english), "English")
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["ru-RU", "en-US"]), .russian)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["ru_RU"]), .russian)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["en-US", "ru-RU"]), .english)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["de-DE"]), .english)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: []), .english)
    }

    func testPlaybackTimelineKeepsMovingWhenTVPositionIsMissingOrStale() {
        var timeline = PlaybackTimeline()
        timeline.reset(position: 120, playing: true, uptime: 10)
        XCTAssertEqual(
            timeline.reconcile(
                reportedPosition: nil, remotePlaying: true, uptime: 15,
                duration: 300, keepClockMoving: true
            ),
            125,
            accuracy: 0.001
        )
        XCTAssertEqual(
            timeline.reconcile(
                reportedPosition: 121, remotePlaying: true, uptime: 20,
                duration: 300, keepClockMoving: true
            ),
            130,
            accuracy: 0.001
        )
        XCTAssertEqual(
            timeline.reconcile(
                reportedPosition: nil, remotePlaying: false, uptime: 25,
                duration: 300, keepClockMoving: true
            ),
            135,
            accuracy: 0.001
        )
        XCTAssertEqual(timeline.estimatedPosition(at: 40, duration: 300), 135, accuracy: 0.001)
    }

    func testTransitioningTransportPreservesPlaybackState() {
        let transitioning = TransportState(name: "TRANSITIONING", position: 10, duration: 100)
        XCTAssertTrue(transitioning.transitioning)
        XCTAssertTrue(transitioning.resolvedPlaying(previous: true))
        XCTAssertFalse(transitioning.resolvedPlaying(previous: false))

        let paused = TransportState(name: "PAUSED_PLAYBACK", position: 10, duration: 100)
        XCTAssertFalse(paused.transitioning)
        XCTAssertFalse(paused.resolvedPlaying(previous: true))
    }

    func testSleepPreventionFollowsSettingAndPlaybackWithoutDuplicateActivities() {
        var started = 0
        var ended = 0
        let token = NSObject()
        let prevention = PlaybackSleepPrevention(
            beginActivity: { started += 1; return token },
            endActivity: {
                XCTAssertTrue(($0 as AnyObject) === token)
                ended += 1
            }
        )

        prevention.update(enabled: false, playing: true)
        prevention.update(enabled: true, playing: false)
        XCTAssertEqual(started, 0)

        prevention.update(enabled: true, playing: true)
        prevention.update(enabled: true, playing: true)
        XCTAssertEqual(started, 1)
        XCTAssertEqual(ended, 0)

        prevention.update(enabled: true, playing: false)
        prevention.update(enabled: true, playing: false)
        XCTAssertEqual(ended, 1)

        prevention.update(enabled: true, playing: true)
        XCTAssertEqual(started, 2)
        prevention.update(enabled: false, playing: true)
        XCTAssertEqual(ended, 2)
    }

    func testSleepPreventionReleasesActivityWhenDestroyed() {
        var ended = 0
        var prevention: PlaybackSleepPrevention? = PlaybackSleepPrevention(
            beginActivity: { NSObject() },
            endActivity: { _ in ended += 1 }
        )
        prevention?.update(enabled: true, playing: true)
        prevention = nil
        XCTAssertEqual(ended, 1)
    }

    func testLocalMediaRange() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DlnaTube-test-\(UUID().uuidString).mp4")
        try Data("abcdefghij".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = try MediaServer()
        server.set(MediaSource(url: nil, fileURL: file, title: "Test", headers: [:]), proxy: nil)
        let device = Renderer(id: "test", name: "Test", controlURL: URL(string: "http://127.0.0.1/")!, serviceType: "AVTransport", host: "127.0.0.1")
        var request = URLRequest(url: try server.url(for: device))
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(String(data: body, encoding: .utf8), "cdef")
    }

    func testYouTubeExtractionWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["DLNATUBE_TEST_YOUTUBE"] == "1" else { return }
        YouTube.networkSession = URLSession(configuration: ProxySettings.configuration(appProxy))
        let url = URL(string: ProcessInfo.processInfo.environment["DLNATUBE_TEST_URL"] ?? "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let methods: [YouTube.ExtractionMethod] = ProcessInfo.processInfo.environment["DLNATUBE_TEST_LOCAL_ONLY"] == "1"
            ? [.local]
            : [.local, .remote]
        let video = YouTube(url: url, methods: methods)
        let streams = try await video.streams
        if ProcessInfo.processInfo.environment["DLNATUBE_INSPECT_FORMATS"] == "1" {
            for stream in streams.sorted(by: { ($0.videoResolution ?? 0) < ($1.videoResolution ?? 0) }) {
                print("FORMAT ext=\(stream.fileExtension) height=\(stream.videoResolution ?? 0) video=\(String(describing: stream.videoCodec)) audio=\(String(describing: stream.audioCodec)) bitrate=\(stream.bitrate ?? 0)")
            }
        }
        XCTAssertFalse(streams.isEmpty)
    }

    func testMediaPreparationWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["DLNATUBE_TEST_MEDIA"] == "1" else { return }
        let url = ProcessInfo.processInfo.environment["DLNATUBE_TEST_URL"] ?? "https://www.youtube.com/watch?v=0mh5d2a8wp0"
        let source = try await MediaExtractor.extract(
            videoURL: url,
            proxy: appProxy
        )
        if ProcessInfo.processInfo.environment["DLNATUBE_INSPECT_FORMATS"] == "1" {
            print("MEDIA_SOURCE title=\(source.title) duration=\(source.duration ?? -1) height=\(source.videoHeight ?? 0) transport=\(source.isTransportStream)")
        }
        if ProcessInfo.processInfo.environment["DLNATUBE_TEST_RANGES"] == "1" {
            for (index, streamURL) in [source.url, source.audioURL].compactMap({ $0 }).enumerated() {
                let client = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "c" })?.value ?? "unknown"
                let size = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "clen" })?.value.flatMap(Int64.init) ?? 1
                for offset in [Int64(0), max(0, size / 2)] {
                    var request = URLRequest(url: streamURL)
                    request.setValue("bytes=\(offset)-\(offset + 524_287)", forHTTPHeaderField: "Range")
                    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (_, response) = try await URLSession(configuration: ProxySettings.configuration(appProxy)).data(for: request)
                    let http = response as? HTTPURLResponse
                    print("RANGE stream=\(index) client=\(client) offset=\(offset) status=\(http?.statusCode ?? 0) contentRange=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "missing")")
                    XCTAssertEqual(http?.statusCode, 206)
                    XCTAssertNotNil(http?.value(forHTTPHeaderField: "Content-Range"))
                }
            }
        }
        XCTAssertFalse(source.title.isEmpty)
        XCTAssertNotNil(source.url)
        XCTAssertNil(source.fileURL)
        if source.isTransportStream {
            XCTAssertNotNil(source.audioURL)
            try MediaBridge.requireAvailable()
        }
    }

    func testDiscoverRenderersWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["DLNATUBE_TEST_DISCOVERY"] == "1" else { return }
        let devices = await SSDP.discover()
        for device in devices {
            print("RENDERER name=\(device.name) host=\(device.host) type=\(device.serviceType)")
            if let capabilities = try? await DLNA.capabilities(device: device) {
                print("CAPABILITIES video=\(capabilities.videoFormats) audio=\(capabilities.audioFormats) resolution=\(capabilities.resolution)")
                if device.name.contains("UE46EH5307") {
                    XCTAssertTrue(capabilities.videoFormats.contains("MPEG-TS"))
                    XCTAssertTrue(capabilities.audioFormats.contains("AAC"))
                }
            }
        }
    }

    func testLiveTransportWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["DLNATUBE_TEST_TRANSPORT"] == "1" else { return }
        let url = ProcessInfo.processInfo.environment["DLNATUBE_TEST_URL"] ?? "https://www.youtube.com/watch?v=0mh5d2a8wp0"
        let source = try await MediaExtractor.extract(videoURL: url, proxy: appProxy, maxVideoHeight: 720)
        XCTAssertTrue(source.isTransportStream)
        try MediaBridge.requireAvailable()
        let server = try MediaServer()
        server.set(source, proxy: appProxy)
        let localDevice = Renderer(id: "local", name: "Local", controlURL: URL(string: "http://127.0.0.1/")!, serviceType: "test", host: "127.0.0.1")
        let localURL = try server.url(for: localDevice)
        let receiver = TransportReceiver()
        let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: localURL)
        let firstStarted = Date()
        task.resume()
        let bytes = try await receiver.firstBytes()
        print("INITIAL_STREAM_SECONDS=\(Date().timeIntervalSince(firstStarted))")
        task.cancel()
        session.invalidateAndCancel()
        XCTAssertGreaterThanOrEqual(bytes.count, 188 * 3)
        XCTAssertEqual(bytes[0], 0x47)
        XCTAssertEqual(bytes[188], 0x47)
        XCTAssertEqual(bytes[376], 0x47)

        server.set(source, proxy: appProxy, startSeconds: 20)
        let seekURL = try server.url(for: localDevice)
        XCTAssertNotEqual(seekURL, localURL)
        let seekReceiver = TransportReceiver()
        let seekSession = URLSession(configuration: .ephemeral, delegate: seekReceiver, delegateQueue: nil)
        let seekTask = seekSession.dataTask(with: seekURL)
        let seekStarted = Date()
        seekTask.resume()
        let seekBytes = try await seekReceiver.firstBytes()
        print("SEEK_STREAM_SECONDS=\(Date().timeIntervalSince(seekStarted))")
        let actualStart = Double((seekTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-DlnaTube-Start") ?? "")
        seekTask.cancel()
        seekSession.invalidateAndCancel()
        XCTAssertEqual(seekBytes[0], 0x47)
        XCTAssertLessThanOrEqual(abs((actualStart ?? 100) - 20), 4)
        XCTAssertEqual(server.playbackStart(), actualStart ?? -1, accuracy: 0.01)
        print("SEEK_ACTUAL_START=\(actualStart ?? -1)")

        for target in [35.0, 47.0] {
            server.set(source, proxy: appProxy, startSeconds: target)
            let receiver = TransportReceiver()
            let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
            let task = session.dataTask(with: try server.url(for: localDevice))
            task.resume()
            let bytes = try await receiver.firstBytes()
            let actual = Double((task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-DlnaTube-Start") ?? "")
            task.cancel()
            session.invalidateAndCancel()
            XCTAssertEqual(bytes[0], 0x47)
            XCTAssertLessThanOrEqual(abs((actual ?? 100) - target), 5)
        }

        if ProcessInfo.processInfo.environment["DLNATUBE_TEST_TV"] == "1" {
            var devices: [Renderer] = []
            for _ in 0..<3 {
                devices = await SSDP.discover()
                if devices.contains(where: { $0.name.contains("UE46EH5307") }) { break }
            }
            let device = try XCTUnwrap(devices.first { $0.name.contains("UE46EH5307") })
            server.set(source, proxy: appProxy)
            let url = try server.url(for: device)
            _ = try? await DLNA.command("Stop", device: device)
            try await DLNA.setMedia(url, title: source.title, device: device, isTransportStream: true)
            let state = try await DLNA.resumePlayback(device: device)
            print("TV_PLAYING=\(state.playing) POSITION=\(state.position) DURATION=\(state.duration)")
            XCTAssertTrue(state.playing)
            if ProcessInfo.processInfo.environment["DLNATUBE_TEST_SEEK"] == "1" {
                _ = try? await DLNA.command("Stop", device: device)
                server.set(source, proxy: appProxy, startSeconds: 20)
                let resumedURL = try server.url(for: device)
                try await DLNA.setMedia(resumedURL, title: source.title, device: device, isTransportStream: true)
                let afterSeek = try await DLNA.resumePlayback(device: device)
                print("TV_RESTART_AT_20 playing=\(afterSeek.playing) position=\(afterSeek.position)")
                XCTAssertTrue(afterSeek.playing)
            }
            _ = try? await DLNA.command("Stop", device: device)
        }
    }
}

private final class TransportReceiver: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?

    func firstBytes() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if data.count >= 188 * 3 { continuation.resume(returning: data) }
            else { self.continuation = continuation }
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        self.data.append(data)
        if self.data.count >= 188 * 3, let continuation {
            self.continuation = nil
            continuation.resume(returning: self.data)
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: error ?? TubeError.message("Поток завершился без данных."))
        }
        lock.unlock()
    }
}
