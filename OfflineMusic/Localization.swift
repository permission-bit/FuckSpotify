import Foundation
#if os(iOS)
import SwiftUI
#endif

/// German source strings are stable catalog keys. Never pass song metadata here.
/// Every lookup reads app.language so changing it does not require relaunching.
enum L10n {
    static let languageKey = "app.language"

    private static var availableLanguages: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }
    }

    static var languageCode: String {
        let selected = UserDefaults.standard.string(forKey: languageKey) ?? "system"
        let preferences = selected == "system" ? Locale.preferredLanguages : [selected]
        return Bundle.preferredLocalizations(from: availableLanguages, forPreferences: preferences).first ?? "de"
    }

    static var locale: Locale { Locale(identifier: languageCode) }

    /// Keep app-owned error keys until rendering; normalize OS errors whose
    /// localizedDescription otherwise follows the device rather than app language.
    static func error(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let native = error as NSError
        if native.domain == NSURLErrorDomain {
            if native.code == URLError.timedOut.rawValue { return "Das Zeitlimit wurde erreicht. Versuche es erneut." }
            return "Keine Netzwerkverbindung. Prüfe dein Netzwerk und versuche es erneut."
        }
        if native.domain == NSCocoaErrorDomain && native.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return "Nicht genug freier Speicherplatz. Gib Speicher frei und versuche den Import erneut."
        }
        return "Der Vorgang konnte nicht abgeschlossen werden. Bitte versuche es erneut."
    }

    private static func bundle(for language: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    private static func translation(_ key: String) -> String {
        // An explicit bundle prevents Foundation from using the device language
        // instead of the in-app selection. German remains the source fallback.
        let fallback = bundle(for: "de")?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        return bundle(for: languageCode)?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback
    }

    static func text(_ key: String) -> String {
        let translated = translation(key)
        if translated != key { return translated }
        // Compatibility for legacy String interpolation. New UI code should use
        // format/count so substitutions remain unambiguous and extractable.
        for template in templates {
            guard let match = template.expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) else { continue }
            let values = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: key).map { String(key[$0]) } }
            if values.count == 1, let count = Int(values[0]), template.isCount {
                return self.count(template.key, count)
            }
            return substitute(translation(template.key), values: values)
        }
        return key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: translation(key), locale: locale, arguments: arguments)
    }

    /// Use a catalog key with an Int64 plural substitution, e.g. "%lld Titel".
    static func count(_ key: String, _ count: Int) -> String {
        String(format: translation(key), locale: locale, arguments: [Int64(count)])
    }

    private struct Template {
        let key: String
        let expression: NSRegularExpression
        let isCount: Bool
        let specificity: Int
    }

    private static let placeholder = try! NSRegularExpression(pattern: #"%(?:([1-9][0-9]*)\$)?(@|lld|ld|d|li|i|llu|lu|u)"#)

    private static let templates: [Template] = {
        var keys = Set<String>()
        for language in ["de", "en"] {
            guard let bundle = bundle(for: language) else { continue }
            for fileExtension in ["strings", "stringsdict"] {
                guard let url = bundle.url(forResource: "Localizable", withExtension: fileExtension),
                      let data = try? Data(contentsOf: url),
                      let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
                keys.formUnion(dictionary.keys)
            }
        }
        return keys.compactMap { key -> Template? in
            // Compiler-typed numeric variants supersede legacy object-count
            // templates, which could accidentally match an unrelated sentence.
            if key.contains("%@"), keys.contains(key.replacingOccurrences(of: "%@", with: "%lld")) { return nil }
            let matches = placeholder.matches(in: key, range: NSRange(key.startIndex..., in: key))
            guard !matches.isEmpty else { return nil }
            var pattern = "\\A", cursor = key.startIndex, literal = ""
            for match in matches {
                guard let range = Range(match.range, in: key), let typeRange = Range(match.range(at: 2), in: key) else { return nil }
                let part = String(key[cursor..<range.lowerBound])
                literal += part
                pattern += NSRegularExpression.escapedPattern(for: part)
                pattern += key[typeRange] == "@" ? "(.*?)" : "([0-9]+)"
                cursor = range.upperBound
            }
            let tail = String(key[cursor...])
            literal += tail
            pattern += NSRegularExpression.escapedPattern(for: tail) + "\\z"
            // Generic metadata formats such as "%@ · %@" must never match.
            guard literal.contains(where: { $0.isLetter }), let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            return Template(key: key, expression: expression, isCount: matches.count == 1 && key.contains("%lld"), specificity: literal.count)
        }.sorted {
            if $0.specificity != $1.specificity { return $0.specificity > $1.specificity }
            if $0.isCount != $1.isCount { return $0.isCount }
            return $0.key < $1.key
        }
    }()

    private static func substitute(_ format: String, values: [String]) -> String {
        let matches = placeholder.matches(in: format, range: NSRange(format.startIndex..., in: format))
        var result = "", cursor = format.startIndex
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: format) else { continue }
            result += format[cursor..<range.lowerBound]
            let position = Range(match.range(at: 1), in: format).flatMap { Int(format[$0]) }.map { $0 - 1 } ?? index
            guard values.indices.contains(position) else { return format }
            result += text(values[position])
            cursor = range.upperBound
        }
        result += format[cursor...]
        return result
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case german = "de"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt-BR"
    case dutch = "nl"
    case polish = "pl"
    case turkish = "tr"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    var locale: Locale {
        self == .system ? L10n.locale : Locale(identifier: rawValue)
    }

    var displayName: String {
        switch self {
        case .system: return L10n.text("System")
        case .german: return "Deutsch"
        case .english: return "English"
        case .spanish: return "Español"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .portuguese: return "Português (Brasil)"
        case .dutch: return "Nederlands"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .chineseSimplified: return "简体中文"
        }
    }
}

#if os(iOS)
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.language") private var languageCode = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker(L10n.text("Sprache"), selection: $languageCode) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
            } header: {
                Text(L10n.text("Allgemein"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Die Sprache der App kann jederzeit geändert werden. Die Änderung wird sofort übernommen."))
                    Text(L10n.text("Deutsch und Englisch sind vollständig übersetzt. Weitere Sprachen sind teilweise übersetzt."))
                }
            }
        }
        .navigationTitle(L10n.text("Einstellungen"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("Fertig")) { dismiss() }
            }
        }
        .musicScreen()
    }
}
#endif
