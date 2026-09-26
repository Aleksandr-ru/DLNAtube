import Foundation
import Darwin

struct Renderer: Identifiable, Hashable {
    let id: String
    let name: String
    let controlURL: URL
    let serviceType: String
    let host: String
    var connectionURL: URL? = nil
    var connectionServiceType: String? = nil
}

enum TubeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum XMLTools {
    static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func fields(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        let delegate = FieldParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.fields
    }
}

private final class FieldParser: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    private var current = ""
    private var buffer = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        current = elementName.components(separatedBy: ":").last ?? elementName
        buffer = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { fields[name] = value }
        current = ""
        buffer = ""
    }
}

private final class DescriptionParser: NSObject, XMLParserDelegate {
    var name = ""
    var udn = ""
    var serviceType = ""
    var controlPath = ""
    var connectionServiceType = ""
    var connectionPath = ""
    private var inService = false
    private var pendingServiceType = ""
    private var pendingControlPath = ""
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "service" {
            inService = true
            pendingServiceType = ""
            pendingControlPath = ""
        }
        buffer = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName": if name.isEmpty { name = value }
        case "UDN": if udn.isEmpty { udn = value }
        case "serviceType": if inService { pendingServiceType = value }
        case "controlURL": if inService { pendingControlPath = value }
        case "service":
            if pendingServiceType.contains(":AVTransport:") && serviceType.isEmpty {
                serviceType = pendingServiceType
                controlPath = pendingControlPath
            } else if pendingServiceType.contains(":ConnectionManager:") && connectionServiceType.isEmpty {
                connectionServiceType = pendingServiceType
                connectionPath = pendingControlPath
            }
            inService = false
        default: break
        }
        buffer = ""
    }
}

enum SSDP {
    static func discover() async -> [Renderer] {
        let locations = await Task.detached(priority: .userInitiated) { searchLocations() }.value
        return await withTaskGroup(of: Renderer?.self) { group in
            for location in locations {
                group.addTask { await describe(location) }
            }
            var found: [String: Renderer] = [:]
            for await renderer in group {
                if let renderer { found[renderer.id] = renderer }
            }
            return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private static func searchLocations() -> [URL] {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return [] }
        defer { close(socketFD) }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)
        let searchTargets = [
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "urn:schemas-upnp-org:service:AVTransport:1",
            "upnp:rootdevice",
            "ssdp:all"
        ]
        for target in searchTargets {
            let query = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
            query.withCString { pointer in
                withUnsafePointer(to: &destination) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(socketFD, pointer, strlen(pointer), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        var urls = Set<URL>()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = recv(socketFD, &bytes, bytes.count, 0)
            if count <= 0 { continue }
            guard let response = String(bytes: bytes.prefix(count), encoding: .utf8) else { continue }
            for line in response.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), url.scheme?.lowercased() == "http" { urls.insert(url) }
            }
        }
        return Array(urls)
    }

    private static func describe(_ location: URL) async -> Renderer? {
        var request = URLRequest(url: location)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let parser = XMLParser(data: data)
        let description = DescriptionParser()
        parser.delegate = description
        guard parser.parse(), !description.serviceType.isEmpty,
              let controlURL = URL(string: description.controlPath, relativeTo: location)?.absoluteURL,
              let host = location.host else { return nil }
        return Renderer(id: description.udn.isEmpty ? location.absoluteString : description.udn,
                        name: description.name.isEmpty ? host : description.name,
                        controlURL: controlURL, serviceType: description.serviceType, host: host,
                        connectionURL: URL(string: description.connectionPath, relativeTo: location)?.absoluteURL,
                        connectionServiceType: description.connectionServiceType.isEmpty ? nil : description.connectionServiceType)
    }
}

struct TransportState {
    let name: String
    let position: Double
    let duration: Double

    var playing: Bool { name == "PLAYING" }
    var transitioning: Bool { name == "TRANSITIONING" }

    func resolvedPlaying(previous: Bool) -> Bool {
        transitioning ? previous : playing
    }
}

struct RendererCapabilities: Equatable {
    enum Resolution: Equatable {
        case profile(Int)
        case unspecifiedHD
        case unspecifiedSD
        case unavailable
    }

    let videoFormats: [String]
    let audioFormats: [String]
    let resolutionKind: Resolution
    let maxVideoHeight: Int?

    var resolution: String { resolutionText() }

    func resolutionText(language: AppLanguage? = nil) -> String {
        switch resolutionKind {
        case .profile(let height):
            return L10n.text("Указан профиль \(height)p", "Reported \(height)p profile", language: language)
        case .unspecifiedHD:
            return L10n.text(
                "Есть HD-профили; точный предел не указан",
                "HD profiles are available; the exact limit is not reported",
                language: language
            )
        case .unspecifiedSD:
            return L10n.text(
                "Есть SD-профили; точный предел не указан",
                "SD profiles are available; the exact limit is not reported",
                language: language
            )
        case .unavailable:
            return L10n.text("Не указано устройством", "Not reported by the device", language: language)
        }
    }

    init(protocolInfo: String) {
        var video = Set<String>()
        var audio = Set<String>()
        var profiles = [String]()
        for entry in protocolInfo.split(separator: ",") {
            let fields = entry.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0].lowercased() == "http-get" else { continue }
            let mime = fields[2].lowercased()
            let properties = String(fields[3]).uppercased()
            if let range = properties.range(of: "DLNA.ORG_PN=") {
                let profile = properties[range.upperBound...].split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                profiles.append(profile)
            }
            switch mime {
            case "video/mp4": video.insert("MP4")
            case "video/vnd.dlna.mpeg-tts", "video/mp2t": video.insert("MPEG-TS")
            case "video/mpeg":
                if properties.contains("_TS_") { video.insert("MPEG-TS") }
                else if properties.contains("_PS_") { video.insert("MPEG-PS") }
                else { video.insert("MPEG") }
            case "video/x-ms-wmv", "video/x-ms-asf": video.insert("WMV")
            case "video/x-msvideo", "video/avi": video.insert("AVI")
            case "video/x-matroska": video.insert("MKV")
            case "video/quicktime": video.insert("MOV")
            case "video/3gpp": video.insert("3GP")
            default: break
            }
            switch mime {
            case "audio/mpeg", "audio/mp3": audio.insert("MP3")
            case "audio/mp4", "audio/x-m4a", "audio/aac", "audio/aacp": audio.insert("AAC")
            case "audio/x-ms-wma": audio.insert("WMA")
            case "audio/wav", "audio/x-wav", "audio/l16": audio.insert("PCM")
            case "audio/flac", "audio/x-flac": audio.insert("FLAC")
            default: break
            }
            if properties.contains("AAC") { audio.insert("AAC") }
            if properties.contains("AC3") || properties.contains("AC-3") { audio.insert("AC-3") }
        }
        videoFormats = Self.ordered(video, preferred: ["MP4", "MPEG-TS", "MPEG-PS", "MPEG", "MKV", "AVI", "WMV", "MOV", "3GP"])
        audioFormats = Self.ordered(audio, preferred: ["AAC", "MP3", "AC-3", "WMA", "PCM", "FLAC"])

        let names = profiles.joined(separator: " ")
        if names.contains("4320P") || names.contains("8K") {
            resolutionKind = .profile(4320)
            maxVideoHeight = 4320
        } else if names.contains("2160P") || names.contains("4K") {
            resolutionKind = .profile(2160)
            maxVideoHeight = 2160
        } else if names.contains("1080P") {
            resolutionKind = .profile(1080)
            maxVideoHeight = 1080
        } else if names.contains("720P") {
            resolutionKind = .profile(720)
            maxVideoHeight = 720
        } else if names.contains("_HD_") {
            resolutionKind = .unspecifiedHD
            maxVideoHeight = 720
        } else if names.contains("_SD_") {
            resolutionKind = .unspecifiedSD
            maxVideoHeight = 480
        } else {
            resolutionKind = .unavailable
            maxVideoHeight = nil
        }
    }

    private static func ordered(_ values: Set<String>, preferred: [String]) -> [String] {
        preferred.filter { values.contains($0) }
    }
}

enum DLNA {
    static func capabilities(device: Renderer) async throws -> RendererCapabilities {
        guard let url = device.connectionURL, let service = device.connectionServiceType else {
            throw TubeError.message(L10n.text(
                "Устройство не предоставляет список поддерживаемых форматов.",
                "The device does not provide a supported format list."
            ))
        }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetProtocolInfo xmlns:u="\(service)"></u:GetProtocolInfo></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#GetProtocolInfo\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TubeError.message(L10n.text(
                "Не удалось получить форматы устройства.",
                "Could not retrieve the device formats."
            ))
        }
        guard let sink = XMLTools.fields(data)["Sink"], !sink.isEmpty else {
            throw TubeError.message(L10n.text(
                "Устройство не сообщает поддерживаемые форматы.",
                "The device did not report its supported formats."
            ))
        }
        return RendererCapabilities(protocolInfo: sink)
    }

    static func command(_ action: String, device: Renderer, arguments: [(String, String)] = [], timeout: TimeInterval = 8) async throws -> [String: String] {
        let parameters = (["<InstanceID>0</InstanceID>"] + arguments.map {
            "<\($0.0)>\(XMLTools.escape($0.1))</\($0.0)>"
        }).joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(device.serviceType)">\(parameters)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(device.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let fields = XMLTools.fields(data)
            throw TubeError.message(fields["errorDescription"] ?? L10n.text(
                "Телевизор отклонил команду \(action).",
                "The TV rejected the \(action) command."
            ))
        }
        return XMLTools.fields(data)
    }

    static func setMedia(_ url: URL, title: String, device: Renderer, isTransportStream: Bool = false) async throws {
        let protocolInfo = isTransportStream
            ? "http-get:*:video/mpeg:DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO;DLNA.ORG_OP=00"
            : "http-get:*:video/mp4:DLNA.ORG_OP=01"
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="0" restricted="1"><dc:title>\(XMLTools.escape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="\(protocolInfo)">\(XMLTools.escape(url.absoluteString))</res></item></DIDL-Lite>
        """
        _ = try await command("SetAVTransportURI", device: device, arguments: [
            ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", didl)
        ])
    }

    static func state(device: Renderer) async throws -> TransportState {
        let transport = try await command("GetTransportInfo", device: device)
        let position = try await command("GetPositionInfo", device: device)
        return TransportState(
            name: transport["CurrentTransportState"] ?? "UNKNOWN",
            position: seconds(position["RelTime"] ?? ""),
            duration: seconds(position["TrackDuration"] ?? "")
        )
    }

    @discardableResult
    static func resumePlayback(device: Renderer, timeout: TimeInterval = 10) async throws -> TransportState {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var nextPlayAttempt: TimeInterval = 0
        var lastError: Error?

        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                let current = try await state(device: device)
                if current.playing { return current }
                let now = ProcessInfo.processInfo.systemUptime
                if !current.transitioning && now >= nextPlayAttempt {
                    do {
                        _ = try await command("Play", device: device, arguments: [("Speed", "1")])
                        nextPlayAttempt = now + 2
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                        nextPlayAttempt = now + 1
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        if let lastError { throw lastError }
        throw TubeError.message(L10n.text(
            "Телевизор не перешёл в режим воспроизведения.",
            "The TV did not enter the playing state."
        ))
    }

    static func seconds(_ clock: String) -> Double {
        let values = clock.split(separator: ":").compactMap { Double($0) }
        guard values.count == 3 else { return 0 }
        return values[0] * 3600 + values[1] * 60 + values[2]
    }

    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
}
