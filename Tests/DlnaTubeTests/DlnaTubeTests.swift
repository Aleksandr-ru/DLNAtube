import XCTest
import YouTubeKit
@testable import DlnaTube

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
        let url = URL(string: ProcessInfo.processInfo.environment["DLNATUBE_TEST_URL"] ?? "https://www.youtube.com/watch?v=7lYBdI3xqqQ")!
        let video = YouTube(url: url, methods: [.local])
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
        let source = try await MediaExtractor.extract(
            videoURL: "https://www.youtube.com/watch?v=0mh5d2a8wp0",
            proxy: appProxy
        )
        XCTAssertFalse(source.title.isEmpty)
        XCTAssertGreaterThan(source.duration ?? 0, 0)
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
        YouTube.networkSession = URLSession(configuration: ProxySettings.configuration(appProxy))
        let video = YouTube(url: URL(string: "https://www.youtube.com/watch?v=0mh5d2a8wp0")!, methods: [.local])
        let streams = try await video.streams
        let picture = try XCTUnwrap(streams.filter { $0.fileExtension == .mp4 && $0.videoCodec == .avc1 && $0.includesVideoTrack && !$0.includesAudioTrack && ($0.videoResolution ?? 0) <= 720 }
            .max { ($0.videoResolution ?? 0) < ($1.videoResolution ?? 0) })
        let sound = try XCTUnwrap(streams.filter { $0.fileExtension == .m4a && $0.audioCodec == .mp4a && $0.includesAudioTrack && !$0.includesVideoTrack }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) })
        let source = MediaSource(url: picture.url, fileURL: nil, title: "DLNA streaming test", headers: ["User-Agent": "Mozilla/5.0"], audioURL: sound.url)
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
            _ = try await DLNA.command("Play", device: device, arguments: [("Speed", "1")])
            try await Task.sleep(nanoseconds: 8_000_000_000)
            let state = try await DLNA.state(device: device)
            print("TV_PLAYING=\(state.playing) POSITION=\(state.position) DURATION=\(state.duration)")
            XCTAssertTrue(state.playing)
            if ProcessInfo.processInfo.environment["DLNATUBE_TEST_SEEK"] == "1" {
                _ = try? await DLNA.command("Stop", device: device)
                server.set(source, proxy: appProxy, startSeconds: 20)
                let resumedURL = try server.url(for: device)
                try await DLNA.setMedia(resumedURL, title: source.title, device: device, isTransportStream: true)
                _ = try await DLNA.command("Play", device: device, arguments: [("Speed", "1")])
                try await Task.sleep(nanoseconds: 5_000_000_000)
                let afterSeek = try await DLNA.state(device: device)
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
