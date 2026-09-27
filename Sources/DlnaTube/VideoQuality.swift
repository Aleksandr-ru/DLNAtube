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

    static let preferencesKey = "desiredVideoHeight"
    static let legacyPreferencesByDeviceKey = "desiredVideoHeightByDevice"

    var id: Int { rawValue }
    var title: String {
        Self.title(for: rawValue)
    }

    var dimensions: String {
        switch self {
        case .p240: return "426 × 240 px"
        case .p360: return "640 × 360 px"
        case .p480: return "854 × 480 px"
        case .p720: return "1280 × 720 px"
        case .p1080: return "1920 × 1080 px"
        case .p1440: return "2560 × 1440 px"
        case .p2160: return "3840 × 2160 px"
        case .p4320: return "7680 × 4320 px"
        }
    }

    var settingsTitle: String {
        "\(title) · \(dimensions)"
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
