import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case russian = "ru"
    case english = "en"

    static let preferenceKey = "appLanguage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    static var current: AppLanguage {
        if let value = UserDefaults.standard.string(forKey: preferenceKey),
           let language = AppLanguage(rawValue: value) {
            return language
        }
        return systemDefault(preferredLanguages: Locale.preferredLanguages)
    }

    static func systemDefault(preferredLanguages: [String]) -> AppLanguage {
        guard let primaryLanguage = preferredLanguages.first else { return .english }
        let languageCode = primaryLanguage
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first?
            .lowercased()
        return languageCode == "ru" ? .russian : .english
    }
}

enum L10n {
    static func text(_ russian: String, _ english: String, language: AppLanguage? = nil) -> String {
        (language ?? AppLanguage.current) == .english ? english : russian
    }
}
