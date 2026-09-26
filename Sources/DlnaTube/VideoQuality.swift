import Foundation

enum VideoQuality: Int, CaseIterable, Identifiable {
    case p240 = 240
    case p360 = 360
    case p480 = 480
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160
    case p4320 = 4320

    static let preferencesByDeviceKey = "desiredVideoHeightByDevice"

    var id: Int { rawValue }
    var title: String {
        Self.title(for: rawValue)
    }

    static func title(for height: Int) -> String {
        switch height {
        case 1440: return "1440p (2K)"
        case 2160: return "2160p (4K)"
        case 4320: return "4320p (8K)"
        default: return "\(height)p"
        }
    }

    static func recommended(maxHeight: Int?) -> VideoQuality {
        guard let maxHeight else { return .p720 }
        return allCases.last(where: { $0.rawValue <= maxHeight }) ?? allCases[0]
    }
}
