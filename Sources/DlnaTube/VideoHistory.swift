import Foundation

struct VideoHistoryEntry: Codable, Identifiable, Equatable {
    var url: String
    var title: String

    var id: String { url }
}
