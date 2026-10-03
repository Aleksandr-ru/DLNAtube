import SwiftUI
import AppKit

@main
struct DlnaTubeApp: App {
    @NSApplicationDelegateAdaptor(DlnaTubeAppDelegate.self) private var appDelegate
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup("DLNAtube") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentSize)
        .commands {
            DLNAtubeCommands(language: model.language)
        }
        Window(L10n.text("Настройки", "Settings", language: model.language), id: "settings") {
            SettingsView(model: model)
                .frame(width: 430)
                .padding(24)
        }
        .windowResizability(.contentSize)
    }
}

private struct DLNAtubeCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let language: AppLanguage

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.text("Настройки…", "Settings…", language: language)) {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button(L10n.text("О программе DLNAtube", "About DLNAtube", language: language)) {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationVersion: version,
                    .version: ""
                ])
            }
        }
    }
}

@MainActor
private final class DlnaTubeAppDelegate: NSObject, NSApplicationDelegate {
    static weak var playerModel: PlayerModel?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let playerModel = Self.playerModel else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true

        Task { @MainActor in
            await playerModel.stopBeforeApplicationExit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.openWindow) private var openWindow
    @State private var scrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: selectedDeviceSelection) {
                    Section {
                        if model.devices.isEmpty {
                            Label(
                                model.discovering
                                    ? L10n.text("Поиск устройств…", "Searching for devices…")
                                    : L10n.text("Устройства не найдены", "No devices found"),
                                systemImage: model.discovering ? "dot.radiowaves.left.and.right" : "tv"
                            )
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(model.devices) { device in
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .lineLimit(1)
                                        Text(device.host)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                } icon: {
                                    Image(systemName: "tv")
                                }
                                .tag(Optional(device.id))
                            }
                        }
                    } header: {
                        Text(L10n.text("Устройства", "Devices"))
                    }
                }
                .listStyle(.sidebar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                deviceCapabilitiesPanel
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
        } detail: {
            playerDetail
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            DlnaTubeAppDelegate.playerModel = model
            model.discover(startup: true)
        }
        .onChange(of: model.selectedDeviceID) { _ in model.loadCapabilities() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.devices.isEmpty { model.discover(startup: true) }
        }
    }

    private var selectedDeviceSelection: Binding<String?> {
        Binding(
            get: { model.selectedDeviceID.isEmpty ? nil : model.selectedDeviceID },
            set: { model.selectedDeviceID = $0 ?? "" }
        )
    }

    private var playerDetail: some View {
        VStack(spacing: 0) {
            VideoHistoryList(
                text: $model.videoURL,
                selectedVideoURL: $model.selectedHistoryURL,
                history: model.videoHistory,
                language: model.language,
                onSelect: { model.playHistoryEntry($0) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    HStack(spacing: 10) {
                        VideoURLHistoryField(
                            text: $model.videoURL,
                            onSubmit: { model.cast() }
                        )
                        .frame(maxWidth: .infinity)

                        if model.preparing {
                            Button(L10n.text("Отменить", "Cancel")) { model.cancelPreparation() }
                        } else {
                            Button(L10n.text("Воспроизвести", "Play")) { model.cast() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.busy || model.selectedDeviceID.isEmpty || model.videoURL.isEmpty)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label(L10n.text("YouTube", "YouTube"), systemImage: "play.rectangle")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(model.title.isEmpty ? L10n.text("Нет воспроизведения", "Nothing playing") : model.title)
                            .font(.headline)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 12) {
                            Button { model.togglePlayback() } label: {
                                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                                    .frame(width: 20)
                            }
                            .help(model.playing ? L10n.text("Пауза", "Pause") : L10n.text("Воспроизвести", "Play"))
                            .disabled(!model.hasMedia || model.busy)

                            Button { model.stop() } label: {
                                Image(systemName: "stop.fill")
                                    .frame(width: 20)
                            }
                            .help(L10n.text("Остановить", "Stop"))
                            .disabled(!model.hasMedia || model.busy)

                            Slider(value: Binding(
                                get: { scrubbing ? scrubTime : model.position },
                                set: { scrubTime = $0; scrubbing = true }
                            ), in: 0...max(model.duration, 1), onEditingChanged: { editing in
                                if !editing && scrubbing {
                                    model.seek(to: scrubTime)
                                    scrubbing = false
                                }
                            })
                            .disabled(!model.hasMedia || !model.canSeek || model.busy || model.duration <= 0)

                            Text("\(formatTime(scrubbing ? scrubTime : model.position)) / \(formatTime(model.duration))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .trailing)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                } label: {
                    Label(L10n.text("Плеер", "Player"), systemImage: "speaker.wave.2")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)

            Divider()
            HStack(spacing: 9) {
                if model.busy || model.discovering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.errorMessage == nil ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .navigationTitle("DLNAtube")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.discover() } label: {
                    Label(L10n.text("Найти устройства", "Find devices"), systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .help(L10n.text("Найти устройства", "Find devices"))
                .disabled(model.discovering)
            }
            ToolbarItem {
                Button { openWindow(id: "settings") } label: {
                    Label(L10n.text("Настройки", "Settings"), systemImage: "gearshape")
                }
                .help(L10n.text("Настройки", "Settings"))
            }
        }
    }

    private var selectedDeviceName: String? {
        model.devices.first(where: { $0.id == model.selectedDeviceID })?.name
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }

    private var deviceCapabilitiesPanel: some View {
        let videoFormats = model.capabilities.map {
            $0.videoFormats.isEmpty ? L10n.text("не объявлены", "not reported") : $0.videoFormats.joined(separator: ", ")
        } ?? capabilityPlaceholder
        let audioFormats = model.capabilities.map {
            $0.audioFormats.isEmpty ? L10n.text("не объявлен", "not reported") : $0.audioFormats.joined(separator: ", ")
        } ?? capabilityPlaceholder
        let resolution = model.capabilities?.resolution ?? capabilityPlaceholder

        return VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("Поддержка DLNA", "DLNA support"), systemImage: "info.circle")
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                capabilityRow(L10n.text("Видео", "Video"), value: videoFormats)
                    .help(model.capabilities?.videoFormats.joined(separator: ", ") ?? capabilityErrorHelp)
                capabilityRow(L10n.text("Звук", "Audio"), value: audioFormats)
                    .help(model.capabilities?.audioFormats.joined(separator: ", ") ?? capabilityErrorHelp)
                capabilityRow(L10n.text("Разрешение", "Resolution"), value: resolution)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func capabilityRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.caption2)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capabilityPlaceholder: String {
        if model.loadingCapabilities { return L10n.text("получение…", "retrieving…") }
        if model.capabilityMessage != nil { return L10n.text("недоступно", "unavailable") }
        return "—"
    }

    private var capabilityErrorHelp: String {
        model.capabilityMessage ?? ""
    }
}

private struct VideoURLHistoryField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("https://www.youtube.com/watch?v=…", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onChange(of: isFocused) { focused in
                guard focused else { return }
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
    }
}

private struct VideoHistoryList: View {
    @Binding var text: String
    @Binding var selectedVideoURL: String?
    let history: [VideoHistoryEntry]
    let language: AppLanguage
    let onSelect: (VideoHistoryEntry) -> Void

    private var isURLInput: Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host else { return false }
        return host.contains(".")
    }

    private var matches: [VideoHistoryEntry] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(history.prefix(10).reversed()) }
        if isURLInput { return Array(history.reversed()) }
        let groups = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !groups.isEmpty else { return Array(history.prefix(10).reversed()) }
        return Array(history.filter { entry in
            let searchableText = "\(entry.url) \(entry.title)"
            return groups.contains { searchableText.localizedStandardContains($0) }
        }.reversed())
    }

    var body: some View {
        GeometryReader { geometry in
            if history.isEmpty {
                Text(L10n.text("История воспроизведения пуста", "Playback history is empty", language: language))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if matches.isEmpty {
                Text(L10n.text("Совпадений не найдено", "No matches found", language: language))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                let listHeight = min(geometry.size.height, CGFloat(matches.count) * 36)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ScrollViewReader { proxy in
                        List(selection: $selectedVideoURL) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
                                let isSelected = selectedVideoURL == entry.id
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                        .foregroundStyle(isSelected ? Color.white : .primary)
                                    Text(entry.url)
                                        .font(.caption)
                                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .frame(height: 36)
                                .contentShape(Rectangle())
                                .tag(entry.id)
                                .id(entry.id)
                                .onTapGesture { onSelect(entry) }
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                                .listRowBackground(
                                    isSelected
                                        ? Color(nsColor: .selectedContentBackgroundColor)
                                        : Color(nsColor: NSColor.alternatingContentBackgroundColors[index.isMultiple(of: 2) ? 0 : 1])
                                )
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity)
                        .frame(height: listHeight)
                        .onAppear { scrollToSelectionOrLatest(using: proxy) }
                        .onChange(of: text) { _ in scrollToSelectionOrLatest(using: proxy) }
                        .onChange(of: selectedVideoURL) { _ in scrollToSelectionOrLatest(using: proxy) }
                        .onChange(of: matches.map(\.id)) { _ in scrollToSelectionOrLatest(using: proxy) }
                        .onChange(of: listHeight) { _ in scrollToSelectionOrLatest(using: proxy) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToSelectionOrLatest(using proxy: ScrollViewProxy) {
        let targetID = matches.first(where: { $0.id == selectedVideoURL })?.id ?? matches.last?.id
        guard let targetID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(targetID, anchor: selectedVideoURL == targetID ? .center : .bottom)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @State private var proxyDraft: String
    @State private var languageDraft: AppLanguage
    @State private var qualityDraft: VideoQuality
    @State private var preventSleepDraft: Bool
    @State private var saveError: String?

    init(model: PlayerModel) {
        self.model = model
        _proxyDraft = State(initialValue: model.proxyURL)
        _languageDraft = State(initialValue: model.language)
        _qualityDraft = State(initialValue: model.desiredQuality)
        _preventSleepDraft = State(initialValue: model.preventSleepDuringPlayback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Настройки", "Settings")).font(.title2.weight(.semibold))
            Picker(L10n.text("Язык", "Language"), selection: $languageDraft) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            Divider()
            Text(L10n.text("Видео", "Video")).font(.headline)
            Picker(L10n.text("Качество видео", "Video quality"), selection: $qualityDraft) {
                ForEach(VideoQuality.allCases) { quality in
                    Text(quality.settingsTitle).tag(quality)
                }
            }
            .pickerStyle(.menu)
            .help(L10n.text("Максимальное желаемое качество видео", "Maximum preferred video quality"))
            Text(L10n.text(
                "Выбранное качество — верхний предел. Такой поток должен быть доступен у ролика и поддерживаться DLNA-устройством.",
                "The selected quality is a maximum. The video must provide a matching stream and the DLNA device must support it.",
                language: model.language
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text(L10n.text("Воспроизведение", "Playback")).font(.headline)
            Toggle(L10n.text(
                "Не давать Mac засыпать во время воспроизведения",
                "Prevent Mac from sleeping during playback"
            ), isOn: $preventSleepDraft)
            .toggleStyle(.checkbox)
            Text(L10n.text(
                "На паузе и после остановки сон снова разрешён. Экран может гаснуть.",
                "Sleep is allowed when paused or stopped. The display can still turn off."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text(L10n.text("Сеть", "Network")).font(.headline)
            Text(L10n.text(
                "Прокси используется для доступа Mac к YouTube и медиапотоку. Поиск телевизора работает через локальную сеть.",
                "The proxy is used by the Mac to access YouTube and the media stream. TV discovery uses the local network."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(L10n.text("Прокси, например http://127.0.0.1:8080", "Proxy, for example http://127.0.0.1:8080"), text: $proxyDraft)
                .textFieldStyle(.roundedBorder)
                .onChange(of: proxyDraft) { _ in saveError = nil }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(L10n.text(
                "Поддерживаются HTTP, HTTPS и SOCKS5. Пустое поле использует системные настройки сети.",
                "HTTP, HTTPS, and SOCKS5 are supported. Leave the field empty to use the system network settings."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("Сохранить", "Save")) { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            proxyDraft = model.proxyURL
            languageDraft = model.language
            qualityDraft = model.desiredQuality
            preventSleepDraft = model.preventSleepDuringPlayback
            saveError = nil
        }
    }

    private func save() {
        if model.saveSettings(proxy: proxyDraft, language: languageDraft, quality: qualityDraft,
                              preventSleep: preventSleepDraft) {
            NSApp.keyWindow?.close()
        } else {
            saveError = model.errorMessage
        }
    }
}
