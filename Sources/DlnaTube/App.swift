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
            DLNAtubeCommands()
        }
        Window("Настройки", id: "settings") {
            SettingsView(model: model)
                .frame(width: 430)
                .padding(24)
        }
        .windowResizability(.contentSize)
    }
}

private struct DLNAtubeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button("О программе DLNAtube") {
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
                Text("Устройство воспроизведения")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Picker("Устройство воспроизведения", selection: $model.selectedDeviceID) {
                        Text("Выберите устройство").tag("")
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.discover()
                    } label: {
                        Label("Найти устройства", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.discovering)
                }
                deviceCapabilitiesPanel
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Ссылка на YouTube")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    VideoURLHistoryField(
                        text: $model.videoURL,
                        history: model.videoHistory,
                        onSubmit: { model.cast() }
                    )
                    .frame(maxWidth: .infinity)
                    Picker("Качество", selection: Binding(
                        get: { model.desiredQuality },
                        set: { model.selectVideoQuality($0) }
                    )) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                    .help("Максимальное желаемое качество видео")
                    .disabled(model.selectedDeviceID.isEmpty)
                    if model.preparing {
                        Button("Отменить") { model.cancelPreparation() }
                    } else {
                        Button("Воспроизвести") { model.cast() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.selectedDeviceID.isEmpty || model.videoURL.isEmpty)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(model.title.isEmpty ? "Нет воспроизведения" : model.title)
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
                .help("Настройки")
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
            $0.videoFormats.isEmpty ? "не объявлены" : $0.videoFormats.joined(separator: ", ")
        } ?? capabilityPlaceholder
        let audioFormats = model.capabilities.map {
            $0.audioFormats.isEmpty ? "не объявлен" : $0.audioFormats.joined(separator: ", ")
        } ?? capabilityPlaceholder
        let resolution = model.capabilities?.resolution ?? capabilityPlaceholder

        return VStack(alignment: .leading, spacing: 5) {
            Text("Поддержка DLNA")
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Видео: \(videoFormats)")
                    .help(model.capabilities?.videoFormats.joined(separator: ", ") ?? capabilityErrorHelp)
                Text("Звук: \(audioFormats)")
                    .help(model.capabilities?.audioFormats.joined(separator: ", ") ?? capabilityErrorHelp)
                Text("Разрешение: \(resolution)")
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
        if model.loadingCapabilities { return "получение…" }
        if model.capabilityMessage != nil { return "недоступно" }
        return "—"
    }

    private var capabilityErrorHelp: String {
        model.capabilityMessage ?? ""
    }
}

private struct VideoURLHistoryField: View {
    @Binding var text: String
    let history: [VideoHistoryEntry]
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
                Text("История воспроизведения пуста")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if matches.isEmpty {
                Text("Совпадений не найдено")
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
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Сеть").font(.title2.weight(.semibold))
            Text("Прокси используется для доступа Mac к YouTube и медиапотоку. Поиск телевизора работает через локальную сеть.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Прокси, например http://127.0.0.1:8080", text: $model.proxyURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .onChange(of: model.proxyURL) { _ in saveError = nil }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Поддерживаются HTTP, HTTPS и SOCKS5. Пустое поле использует системные настройки сети.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Сохранить") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func save() {
        if model.saveProxy() {
            NSApp.keyWindow?.close()
        } else {
            saveError = model.errorMessage
        }
    }
}
