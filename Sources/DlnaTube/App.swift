import SwiftUI
import AppKit

@main
struct DlnaTubeApp: App {
    @NSApplicationDelegateAdaptor(DlnaTubeAppDelegate.self) private var appDelegate
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup("DLNAtube") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 450)
        }
        .defaultSize(width: 600, height: 450)
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
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                if let iconURL = Bundle.main.url(forResource: "DlnaTube", withExtension: "icns"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 25, height: 25)
                }
                Text("DLNAtube")
                    .font(.title2.weight(.semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("Устройство воспроизведения", "Playback device"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Picker(L10n.text("Устройство воспроизведения", "Playback device"), selection: $model.selectedDeviceID) {
                        Text(L10n.text("Выберите устройство", "Select a device")).tag("")
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.discover()
                    } label: {
                        Label(L10n.text("Найти устройства", "Find devices"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.discovering)
                }
                deviceCapabilitiesPanel
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("Ссылка на YouTube", "YouTube URL"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    VideoURLHistoryField(
                        text: $model.videoURL,
                        history: model.videoHistory,
                        language: model.language,
                        onSubmit: { model.cast() }
                    )
                    .frame(maxWidth: .infinity)
                    Picker(L10n.text("Качество", "Quality"), selection: Binding(
                        get: { model.desiredQuality },
                        set: { model.selectVideoQuality($0) }
                    )) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                    .help(L10n.text("Максимальное желаемое качество видео", "Maximum preferred video quality"))
                    .disabled(model.selectedDeviceID.isEmpty)
                    if model.preparing {
                        Button(L10n.text("Отменить", "Cancel")) { model.cancelPreparation() }
                    } else {
                        Button(L10n.text("Воспроизвести", "Play")) { model.cast() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.selectedDeviceID.isEmpty || model.videoURL.isEmpty)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(model.title.isEmpty ? L10n.text("Нет воспроизведения", "Nothing playing") : model.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 14) {
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .frame(width: 20)
                    }
                    .disabled(!model.hasMedia || model.busy)
                    Button { model.stop() } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 20)
                    }
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
            HStack {
                if model.busy || model.discovering { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                Spacer()
                Button {
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help(L10n.text("Настройки", "Settings"))
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .onAppear {
            DlnaTubeAppDelegate.playerModel = model
            model.discover(startup: true)
        }
        .onChange(of: model.selectedDeviceID) { _ in model.loadCapabilities() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.devices.isEmpty { model.discover(startup: true) }
        }
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

        return VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Поддержка DLNA", "DLNA support"))
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Видео: \(videoFormats)", "Video: \(videoFormats)"))
                    .help(model.capabilities?.videoFormats.joined(separator: ", ") ?? capabilityErrorHelp)
                Text(L10n.text("Звук: \(audioFormats)", "Audio: \(audioFormats)"))
                    .help(model.capabilities?.audioFormats.joined(separator: ", ") ?? capabilityErrorHelp)
                Text(L10n.text("Разрешение: \(resolution)", "Resolution: \(resolution)"))
            }
            .font(.caption)
            .lineLimit(1)
            .frame(height: 48, alignment: .topLeading)
            .clipped()
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .frame(height: 89, alignment: .topLeading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
    let history: [VideoHistoryEntry]
    let language: AppLanguage
    let onSubmit: () -> Void

    @State private var showingChoices = false
    @State private var skipNextSearchUpdate = false
    @FocusState private var fieldFocused: Bool

    private var matches: [VideoHistoryEntry] {
        let groups = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !groups.isEmpty else { return Array(history.prefix(10)) }
        return history.filter { entry in
            let searchableText = "\(entry.url) \(entry.title)"
            return groups.contains { searchableText.localizedStandardContains($0) }
        }
    }

    var body: some View {
        TextField("https://www.youtube.com/watch?v=…", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onChange(of: fieldFocused) { focused in
                if focused { showingChoices = true }
            }
            .onChange(of: text) { _ in
                if skipNextSearchUpdate {
                    skipNextSearchUpdate = false
                    return
                }
                showingChoices = true
            }
            .onSubmit {
                showingChoices = false
                onSubmit()
            }
            .popover(isPresented: $showingChoices, arrowEdge: .bottom) {
                choices
            }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 0) {
            if history.isEmpty {
                Text(L10n.text("История воспроизведения пуста", "Playback history is empty", language: language))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if matches.isEmpty {
                Text(L10n.text("Совпадений не найдено", "No matches found", language: language))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { entry in
                            Button {
                                if text == entry.url {
                                    skipNextSearchUpdate = false
                                } else {
                                    skipNextSearchUpdate = true
                                    text = entry.url
                                }
                                showingChoices = false
                            } label: {
                                Text(entry.title)
                                    .font(.system(size: 13))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: max(52, min(280, CGFloat(matches.count) * 54)))
    }
}

struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @State private var proxyDraft: String
    @State private var languageDraft: AppLanguage
    @State private var saveError: String?

    init(model: PlayerModel) {
        self.model = model
        _proxyDraft = State(initialValue: model.proxyURL)
        _languageDraft = State(initialValue: model.language)
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
            saveError = nil
        }
    }

    private func save() {
        if model.saveSettings(proxy: proxyDraft, language: languageDraft) {
            NSApp.keyWindow?.close()
        } else {
            saveError = model.errorMessage
        }
    }
}
