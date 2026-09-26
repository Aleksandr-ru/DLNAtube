import Foundation
import OSLog

enum StreamingLog {
    static let stream = Logger(subsystem: ProxySettings.preferencesDomain, category: "Streaming")
    static let dlna = Logger(subsystem: ProxySettings.preferencesDomain, category: "DLNA")
}
