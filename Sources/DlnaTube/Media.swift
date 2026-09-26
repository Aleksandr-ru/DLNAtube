import Foundation
import CFNetwork
import Darwin
import YouTubeKit

struct MediaSource {
    let url: URL?
    let fileURL: URL?
    let title: String
    let headers: [String: String]
    var audioURL: URL? = nil
    var duration: Double? = nil
    var videoHeight: Int? = nil
    var isTransportStream: Bool { audioURL != nil }
}

enum ProxySettings {
    static let preferencesDomain = "ru.aleksandr.dlnatube"
    static let preferenceKey = "proxyURL"
    static let defaultURL = "http://localhost:10809"

    static func normalized(_ value: String) throws -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(),
              ["http", "https", "socks5"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              let port = parts.port, (1...65535).contains(port) else {
            throw TubeError.message(L10n.text(
                "Укажите прокси в виде http://host:port или socks5://host:port.",
                "Enter the proxy as http://host:port or socks5://host:port."
            ))
        }
        return text
    }

    static func configuration(_ value: String?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        guard let value, let parts = URLComponents(string: value),
              let host = parts.host, let port = parts.port else {
            return config
        }
        if parts.scheme == "socks5" {
            config.connectionProxyDictionary = [
                kCFStreamPropertySOCKSProxyHost as String: host,
                kCFStreamPropertySOCKSProxyPort as String: port,
                kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5,
                kCFStreamPropertySOCKSUser as String: parts.user ?? "",
                kCFStreamPropertySOCKSPassword as String: parts.password ?? ""
            ]
        } else {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        }
        return config
    }
}

enum MediaExtractor {
    static func extract(videoURL: String, proxy: String?, maxVideoHeight: Int = 720,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MediaSource {
        guard let url = URL(string: videoURL),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"].contains(host) else {
            throw TubeError.message(L10n.text(
                "Введите HTTPS-ссылку на YouTube.",
                "Enter an HTTPS YouTube URL."
            ))
        }
        let session = URLSession(configuration: ProxySettings.configuration(proxy))
        YouTube.networkSession = session
        // YouTube changes its private player API frequently. Keep the fast local
        // extractor first, then use YouTubeKit's maintained service when the
        // bundled extractor can no longer understand a response.
        let video = YouTube(url: url, methods: [.local, .remote])
        progress(L10n.text("Поиск доступных потоков YouTube…", "Searching for available YouTube streams…"))
        let streams = try await withThrowingTaskGroup(of: [YouTubeKit.Stream].self) { group in
            group.addTask { try await video.streams }
            group.addTask {
                try await Task.sleep(nanoseconds: 90_000_000_000)
                throw TubeError.message(L10n.text(
                    "YouTube не ответил за 90 секунд. Проверьте прокси и попробуйте ещё раз.",
                    "YouTube did not respond within 90 seconds. Check the proxy and try again."
                ))
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        try Task.checkCancellation()
        progress(L10n.text("Получение названия и выбор формата…", "Retrieving the title and selecting a format…"))
        let metadata = try? await video.metadata
        let title = metadata?.title ?? L10n.text("YouTube-видео", "YouTube video")
        let duration = metadata?.duration
        let headers = ["User-Agent": "Mozilla/5.0"]
        let combinedStreams = streams.filter { $0.fileExtension == .mp4 && $0.includesVideoAndAudioTrack && $0.videoCodec == .avc1 && $0.audioCodec == .mp4a }
        let videoStreams = streams.filter { $0.fileExtension == .mp4 && $0.includesVideoTrack && !$0.includesAudioTrack && $0.videoCodec == .avc1 }
        guard let selectedVideo = preferredVideo(combinedStreams + videoStreams, maxHeight: maxVideoHeight) else {
            throw TubeError.message(L10n.text(
                "Для этого видео нет совместимого потока H.264.",
                "No compatible H.264 stream is available for this video."
            ))
        }
        if selectedVideo.includesVideoAndAudioTrack {
            let combined = selectedVideo
            StreamingLog.stream.info("Selected combined MP4: height=\(combined.videoResolution ?? 0), bitrate=\(combined.bitrate ?? 0), duration=\(duration ?? 0, format: .fixed(precision: 3))")
            return MediaSource(url: combined.url, fileURL: nil, title: title, headers: headers,
                               duration: duration, videoHeight: combined.videoResolution)
        }
        let videoStream = selectedVideo
        guard let audioStream = streams
                .filter({ $0.fileExtension == .m4a && $0.includesAudioTrack && !$0.includesVideoTrack && $0.audioCodec == .mp4a })
                .max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) else {
            throw TubeError.message(L10n.text(
                "Для этого видео нет совместимых потоков H.264 и AAC.",
                "No compatible H.264 and AAC streams are available for this video."
            ))
        }
        progress(L10n.text("Подготовка потоковой передачи…", "Preparing the stream…"))
        StreamingLog.stream.info("Selected split streams: videoHeight=\(videoStream.videoResolution ?? 0), videoBitrate=\(videoStream.bitrate ?? 0), audioBitrate=\(audioStream.bitrate ?? 0), duration=\(duration ?? 0, format: .fixed(precision: 3))")
        return MediaSource(url: videoStream.url, fileURL: nil, title: title, headers: headers,
                           audioURL: audioStream.url, duration: duration,
                           videoHeight: videoStream.videoResolution)
    }

    private static func preferredVideo(_ streams: [YouTubeKit.Stream], maxHeight: Int) -> YouTubeKit.Stream? {
        let known = streams.filter { ($0.videoResolution ?? 0) > 0 }
        guard !known.isEmpty else { return streams.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) } }
        guard let targetHeight = preferredHeight(known.compactMap(\.videoResolution), maxHeight: maxHeight) else {
            return nil
        }
        let atTarget = known.filter { $0.videoResolution == targetHeight }
        let combined = atTarget.filter(\.includesVideoAndAudioTrack)
        return (combined.isEmpty ? atTarget : combined)
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
    }

    static func preferredHeight(_ heights: [Int], maxHeight: Int) -> Int? {
        let available = Set(heights.filter { $0 > 0 })
        return available.filter { $0 <= maxHeight }.max() ?? available.min()
    }
}

final class MediaServer {
    private let listenFD: Int32
    let port: UInt16
    private let token = UUID().uuidString
    private let lock = NSLock()
    private var media: MediaSource?
    private var proxy: String?
    private var playbackToken = UUID().uuidString
    private var startSeconds: Double = 0
    private var actualStartSeconds: Double = 0
    private var streamCompleted = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TubeError.message(L10n.text("Не удалось открыть локальный сервер.", "Could not open the local server."))
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw TubeError.message(L10n.text("Не удалось запустить локальный сервер.", "Could not start the local server."))
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(fd, withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &size)
        listenFD = fd
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    deinit { close(listenFD) }

    func set(_ source: MediaSource, proxy: String?, startSeconds: Double = 0) {
        lock.lock()
        media = source
        self.proxy = proxy
        self.startSeconds = max(0, startSeconds)
        actualStartSeconds = self.startSeconds
        streamCompleted = false
        playbackToken = UUID().uuidString
        lock.unlock()
        let kind = source.isTransportStream ? "mpeg-ts" : "mp4"
        StreamingLog.stream.info("Media source set: kind=\(kind, privacy: .public), start=\(startSeconds, format: .fixed(precision: 3)), duration=\(source.duration ?? 0, format: .fixed(precision: 3))")
    }

    func playbackStart() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return actualStartSeconds
    }

    func playbackCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streamCompleted
    }

    func url(for device: Renderer) throws -> URL {
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(80).bigEndian
        guard inet_pton(AF_INET, device.host, &remote.sin_addr) == 1 || Self.resolve(device.host, into: &remote) else {
            throw TubeError.message(L10n.text("Не удалось определить адрес телевизора.", "Could not resolve the TV address."))
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw TubeError.message(L10n.text("Нет сетевого соединения с телевизором.", "There is no network connection to the TV."))
        }
        defer { close(fd) }
        let result = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw TubeError.message(L10n.text("Нет сетевого маршрута к телевизору.", "There is no network route to the TV."))
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard named == 0, inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(buffer.count)) != nil else {
            throw TubeError.message(L10n.text("Не удалось определить локальный IP-адрес Mac.", "Could not determine the Mac's local IP address."))
        }
        lock.lock()
        let transportStream = media?.isTransportStream == true
        let playbackToken = self.playbackToken
        lock.unlock()
        let ext = transportStream ? "ts" : "mp4"
        return URL(string: "http://\(String(cString: buffer)):\(port)/\(token)/\(playbackToken)/video.\(ext)")!
    }

    private static func resolve(_ host: String, into address: inout sockaddr_in) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return false }
        defer { freeaddrinfo(result) }
        address.sin_addr = result.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        return true
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        let requestID = String(UUID().uuidString.prefix(8))
        StreamingLog.stream.info("TV HTTP request accepted: id=\(requestID, privacy: .public)")
        defer { StreamingLog.stream.info("TV HTTP request closed: id=\(requestID, privacy: .public)") }
        defer { close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var requestData = Data()
        while requestData.count < 32_768 && !requestData.containsSubsequence(Data("\r\n\r\n".utf8)) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 {
                StreamingLog.stream.error("TV request header read failed: id=\(requestID, privacy: .public), errno=\(errno)")
                return
            }
            requestData.append(contentsOf: buffer.prefix(count))
        }
        guard let requestText = String(data: requestData, encoding: .utf8),
              let first = requestText.components(separatedBy: "\r\n").first else {
            StreamingLog.stream.error("Invalid TV HTTP request: id=\(requestID, privacy: .public)")
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2,
              ["GET", "HEAD"].contains(String(parts[0])) else {
            _ = writeAll(client, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        StreamingLog.stream.info("TV HTTP request parsed: id=\(requestID, privacy: .public), method=\(String(parts[0]), privacy: .public)")
        lock.lock()
        let source = media
        let proxy = self.proxy
        let startSeconds = self.startSeconds
        let playbackToken = self.playbackToken
        lock.unlock()
        guard let source else { return }
        let expectedPath = "/\(token)/\(playbackToken)/video.\(source.isTransportStream ? "ts" : "mp4")"
        guard parts[1] == expectedPath else {
            StreamingLog.stream.error("TV requested stale or unknown media URL: id=\(requestID, privacy: .public)")
            _ = writeAll(client, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        if let video = source.url, let audio = source.audioURL {
            if parts[0] == "HEAD" {
                _ = writeAll(client, Data("HTTP/1.1 200 OK\r\nContent-Type: video/mpeg\r\ntransferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO;DLNA.ORG_OP=00\r\nConnection: close\r\n\r\n".utf8))
            } else {
                let completed = MediaBridge.stream(
                    video: video, audio: audio, proxy: proxy,
                    startSeconds: startSeconds, client: client, requestID: requestID
                ) { [weak self] actual in
                    guard let self else { return }
                    self.lock.lock()
                    if self.playbackToken == playbackToken { self.actualStartSeconds = max(0, actual) }
                    self.lock.unlock()
                }
                lock.lock()
                if self.playbackToken == playbackToken { streamCompleted = completed }
                lock.unlock()
            }
            return
        }
        if let file = source.fileURL {
            serveFile(file, requestText: requestText, headOnly: parts[0] == "HEAD", client: client)
            return
        }
        guard let remoteURL = source.url else { return }
        var request = URLRequest(url: remoteURL)
        request.httpMethod = String(parts[0])
        request.timeoutInterval = 30
        for (key, value) in source.headers { request.setValue(value, forHTTPHeaderField: key) }
        for line in requestText.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("range:") {
            request.setValue(line.dropFirst(6).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
        }
        let delegate = RelayDelegate(client: client, headOnly: parts[0] == "HEAD", requestID: requestID)
        // A per-connection delegate is required so response bytes can go straight to the TV.
        let streamingSession = URLSession(configuration: ProxySettings.configuration(proxy), delegate: delegate, delegateQueue: nil)
        let streamingTask = streamingSession.dataTask(with: request)
        delegate.task = streamingTask
        streamingTask.resume()
        delegate.finished.wait()
        streamingSession.invalidateAndCancel()
    }

    private func serveFile(_ file: URL, requestText: String, headOnly: Bool, client: Int32) {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber else { return }
        defer { try? handle.close() }
        let total = size.int64Value
        var start: Int64 = 0
        var end = max(total - 1, 0)
        let rangeLine = requestText.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
        if let rangeLine,
           let value = rangeLine.split(separator: "=", maxSplits: 1).last,
           let first = value.split(separator: "-", omittingEmptySubsequences: false).first,
           let parsed = Int64(first), parsed >= 0 {
            start = parsed
            let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
            if pieces.count > 1, let last = Int64(pieces[1]) { end = min(end, last) }
        }
        guard total > 0, start < total, end >= start else {
            _ = writeAll(client, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let partial = rangeLine != nil
        let status = partial ? "206 Partial Content" : "200 OK"
        var header = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        header += "Connection: close\r\n\r\n"
        guard writeAll(client, Data(header.utf8)), !headOnly else { return }
        do {
            try handle.seek(toOffset: UInt64(start))
            var remaining = end - start + 1
            while remaining > 0 {
                let chunk = try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
                if chunk.isEmpty || !writeAll(client, chunk) { break }
                remaining -= Int64(chunk.count)
            }
        } catch { return }
    }
}

private final class RelayDelegate: NSObject, URLSessionDataDelegate {
    let client: Int32
    let headOnly: Bool
    let finished = DispatchSemaphore(value: 0)
    weak var task: URLSessionTask?
    private var sentHeaders = false
    private let requestID: String

    init(client: Int32, headOnly: Bool, requestID: String) {
        self.client = client
        self.headOnly = headOnly
        self.requestID = requestID
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        StreamingLog.stream.info("Direct MP4 response: id=\(self.requestID, privacy: .public), status=\(http.statusCode)")
        var header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
            if let value = http.value(forHTTPHeaderField: name) { header += "\(name): \(value)\r\n" }
        }
        if http.value(forHTTPHeaderField: "Content-Type") == nil { header += "Content-Type: video/mp4\r\n" }
        header += "Connection: close\r\n\r\n"
        sentHeaders = writeAll(client, Data(header.utf8))
        completionHandler(sentHeaders ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !headOnly && !writeAll(client, data) {
            StreamingLog.stream.error("TV closed direct MP4 connection: id=\(self.requestID, privacy: .public), errno=\(errno)")
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            StreamingLog.stream.error("Direct MP4 relay ended with error: id=\(self.requestID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
        } else {
            StreamingLog.stream.info("Direct MP4 relay completed: id=\(self.requestID, privacy: .public)")
        }
        if !sentHeaders {
            _ = writeAll(client, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        }
        finished.signal()
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let sent = send(fd, base.advanced(by: offset), raw.count - offset, 0)
            if sent <= 0 { return false }
            offset += sent
        }
        return true
    }
}

private extension Data {
    func containsSubsequence(_ needle: Data) -> Bool { range(of: needle) != nil }
}
