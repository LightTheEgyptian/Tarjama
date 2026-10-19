import Foundation
import NaturalLanguage

struct Lang: Identifiable, Hashable {
    let code: String
    let native: String
    var id: String { code }
}

enum Langs {
    static let targets: [Lang] = [
        Lang(code: "en", native: "English"),
        Lang(code: "ar", native: "العربية"),
        Lang(code: "fr", native: "Français"),
    ]

    static func detect(_ text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue ?? "en"
    }

    /// Arabic goes to English; everything else goes to Arabic, except French which goes to English.
    static func defaultTarget(for source: String) -> String {
        switch source {
        case "ar": return "en"
        case "en": return "ar"
        default: return "en"
        }
    }

    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    static func isRTL(_ code: String) -> Bool { ["ar", "he", "fa", "ur"].contains(code) }

    static func voice(_ code: String) -> String {
        switch code {
        case "ar": return "ar-SA"
        case "fr": return "fr-FR"
        case "en": return "en-US"
        default: return code
        }
    }
}
