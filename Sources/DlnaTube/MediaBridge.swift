import Foundation
import Darwin

enum MediaBridge {
    typealias ReadFunction = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int64, UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32
    typealias StartFunction = @convention(c) (UnsafeMutableRawPointer?, Double) -> Void
    typealias StreamFunction = @convention(c) (
        Int64, Int64, Double, Int32, UnsafeMutableRawPointer?, ReadFunction, StartFunction
    ) -> Int32

    private static let function: StreamFunction? = {
        let environment = ProcessInfo.processInfo.environment["DLNATUBE_MEDIA_LIBRARY"]
        let candidates = [
            environment,
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libDlnaTubeMedia.dylib").path,
            "Vendor/FFmpeg/lib/libDlnaTubeMedia.dylib"
        ].compactMap { $0 }
        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
                  let symbol = dlsym(handle, "dlnatube_stream_ts") else { continue }
            return unsafeBitCast(symbol, to: StreamFunction.self)
        }
        return nil
    }()

    private static let readCallback: ReadFunction = { opaque, index, offset, buffer, count in
        guard let opaque, let buffer, index == 0 || index == 1 else { return -1 }
        let provider = Unmanaged<RangeProvider>.fromOpaque(opaque).takeUnretainedValue()
        return provider.read(index: Int(index), offset: offset, buffer: buffer, count: Int(count))
    }

    private static let startCallback: StartFunction = { opaque, actualStart in
        guard let opaque else { return }
        let provider = Unmanaged<RangeProvider>.fromOpaque(opaque).takeUnretainedValue()
        provider.onStart(actualStart)
    }

    static func requireAvailable() throws {
        guard function != nil else {
            throw TubeError.message("Библиотека потокового видео не найдена. Соберите приложение через scripts/build-app.sh.")
        }
    }

    static func stream(video: URL, audio: URL, proxy: String?, startSeconds: Double,
                       client: Int32, requestID: String, onStart: @escaping (Double) -> Void) {
        guard let function,
              let provider = RangeProvider(video: video, audio: audio, proxy: proxy,
                                           requestID: requestID, onStart: onStart) else {
            StreamingLog.stream.error("MPEG-TS initialization failed: id=\(requestID, privacy: .public)")
            sendBadGateway(client)
            return
        }
        StreamingLog.stream.info("MPEG-TS started: id=\(requestID, privacy: .public), videoBytes=\(provider.sizes[0]), audioBytes=\(provider.sizes[1]), start=\(startSeconds, format: .fixed(precision: 3))")
        let opaque = Unmanaged.passUnretained(provider).toOpaque()
        let result: Int32 = withExtendedLifetime(provider) {
            function(provider.sizes[0], provider.sizes[1], startSeconds,
                     client, opaque, readCallback, startCallback)
        }
        if result >= 0 {
            StreamingLog.stream.info("MPEG-TS completed normally: id=\(requestID, privacy: .public), result=\(result)")
        } else {
            StreamingLog.stream.error("MPEG-TS stopped: id=\(requestID, privacy: .public), result=\(result), reason=\(resultDescription(result), privacy: .public)")
        }
    }

    private static func resultDescription(_ result: Int32) -> String {
        switch result {
        case -EPIPE: return "broken pipe: TV closed the connection"
        case -ECONNRESET: return "connection reset by TV"
        case -ETIMEDOUT: return "socket timed out"
        case -EIO: return "input read failed"
        default: return "FFmpeg error"
        }
    }

    private static func sendBadGateway(_ client: Int32) {
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        response.withCString { pointer in _ = send(client, pointer, strlen(pointer), 0) }
    }
}

private final class RangeProvider {
    let sizes: [Int64]
    let onStart: (Double) -> Void
    private let session: URLSession
    private let readers: [HTTPRangeReader]

    init?(video: URL, audio: URL, proxy: String?, requestID: String,
          onStart: @escaping (Double) -> Void) {
        let urls = [video, audio]
        let rangeSession = URLSession(configuration: ProxySettings.configuration(proxy))
        let sizes = urls.map { url -> Int64? in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            return items?.first(where: { $0.name == "clen" })?.value.flatMap(Int64.init)
                ?? Self.fetchSize(url: url, session: rangeSession, requestID: requestID)
        }
        guard sizes.allSatisfy({ ($0 ?? 0) > 0 }) else {
            StreamingLog.stream.error("Could not determine stream sizes: id=\(requestID, privacy: .public)")
            rangeSession.invalidateAndCancel()
            return nil
        }
        let resolvedSizes = sizes.map { $0! }
        session = rangeSession
        self.sizes = resolvedSizes
        self.onStart = onStart
        readers = zip(urls, resolvedSizes).enumerated().map {
            HTTPRangeReader(url: $0.element.0, size: $0.element.1, session: rangeSession,
                            requestID: requestID, streamIndex: $0.offset)
        }
    }

    deinit { session.invalidateAndCancel() }

    private static func fetchSize(url: URL, session: URLSession, requestID: String) -> Int64? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let finished = DispatchSemaphore(value: 0)
        var total: Int64?
        var failure = "invalid response"
        let task = session.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse,
               http.statusCode == 206,
               let value = http.value(forHTTPHeaderField: "Content-Range") {
                total = value.split(separator: "/").last.flatMap { Int64($0) }
            } else if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse {
                failure = "status=\(http.statusCode)"
            }
            finished.signal()
        }
        task.resume()
        guard finished.wait(timeout: .now() + 12) == .success else {
            task.cancel()
            StreamingLog.stream.error("Stream size request timed out: id=\(requestID, privacy: .public)")
            return nil
        }
        if total == nil {
            StreamingLog.stream.error("Stream size request failed: id=\(requestID, privacy: .public), error=\(failure, privacy: .public)")
        }
        return total
    }

    func read(index: Int, offset: Int64, buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
        readers[index].read(offset: offset, buffer: buffer, count: count)
    }
}

private final class HTTPRangeReader {
    private let url: URL
    private let size: Int64
    private let session: URLSession
    private var cacheStart: Int64 = -1
    private var cache = Data()
    private let requestID: String
    private let streamIndex: Int

    init(url: URL, size: Int64, session: URLSession, requestID: String, streamIndex: Int) {
        self.url = url
        self.size = size
        self.session = session
        self.requestID = requestID
        self.streamIndex = streamIndex
    }

    func read(offset: Int64, buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
        guard offset >= 0, offset < size, count > 0 else { return 0 }
        if offset < cacheStart || offset >= cacheStart + Int64(cache.count) {
            let length = Int(min(Int64(max(count, 512 * 1024)), size - offset))
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let finished = DispatchSemaphore(value: 0)
            var received: Data?
            var failure = "request did not complete"
            let task = session.dataTask(with: request) { data, response, error in
                let http = response as? HTTPURLResponse
                if error == nil, let http = response as? HTTPURLResponse,
                   http.statusCode == 206,
                   let range = http.value(forHTTPHeaderField: "Content-Range"),
                   range.split(separator: " ").last?.split(separator: "-").first.flatMap({ Int64($0) }) == offset,
                   let data, !data.isEmpty {
                    received = data
                } else if let error {
                    failure = error.localizedDescription
                } else {
                    let range = http?.value(forHTTPHeaderField: "Content-Range") ?? "missing"
                    failure = "status=\(http?.statusCode ?? 0), range=\(range), bytes=\(data?.count ?? 0)"
                }
                finished.signal()
            }
            task.resume()
            let waitResult = finished.wait(timeout: .now() + 17)
            guard waitResult == .success, let received else {
                task.cancel()
                if waitResult != .success { failure = "wait timeout after 17 seconds" }
                StreamingLog.stream.error("Range read failed: id=\(self.requestID, privacy: .public), stream=\(self.streamIndex), offset=\(offset), length=\(length), error=\(failure, privacy: .public)")
                return -1
            }
            cacheStart = offset
            cache = received
        }
        let start = Int(offset - cacheStart)
        let available = min(count, cache.count - start)
        guard available > 0 else { return -1 }
        cache.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer, base.advanced(by: start), available) }
        }
        return Int32(available)
    }
}
