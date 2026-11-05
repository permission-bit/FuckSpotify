// Built by check_localization.py with the unmodified production helper and
// xcstringstool output in an isolated application bundle. No app library used.
import Foundation

@main
struct LocalizationChecks {
    enum FixtureError: LocalizedError {
        case appOwned
        var errorDescription: String? { "Die Verarbeitung wurde abgebrochen." }
    }
    struct Lookup: Decodable {
        let language: String
        let key: String
        let expected: String
        let table: String?
        let count: Int?
    }

    static var failures: [String] = []
    static var checks = 0

    static func equal(_ actual: String, _ expected: String, _ context: String) {
        checks += 1
        if actual != expected {
            failures.append("\(context): expected \(String(reflecting: expected)); got \(String(reflecting: actual))")
        }
    }

    static func main() throws {
        // Keep persistent preferences for this uniquely named test bundle empty.
        // The volatile domain overrides reads without changing the user's app.
        let domain = UserDefaults.argumentDomain
        let original = UserDefaults.standard.volatileDomain(forName: domain)
        func select(_ language: String) {
            UserDefaults.standard.setVolatileDomain([L10n.languageKey: language], forName: domain)
            equal(L10n.languageCode, language, "selected language")
        }
        defer { UserDefaults.standard.setVolatileDomain(original, forName: domain) }
        let cases = try JSONDecoder().decode([Lookup].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for language in ["de", "en", "de"] {
            select(language)
            for item in cases where item.language == language {
                if let count = item.count {
                    equal(L10n.count(item.key, count), item.expected, "\(language) compiled plural \(item.key) \(count)")
                } else if let table = item.table {
                    let path = Bundle.main.path(forResource: language, ofType: "lproj")!
                    let bundle = Bundle(path: path)!
                    equal(bundle.localizedString(forKey: item.key, value: nil, table: table), item.expected, "\(language) \(table) \(item.key)")
                } else {
                    equal(L10n.text(item.key), item.expected, "\(language) plain \(item.key)")
                }
            }
        }
        // Independent semantic expectations: these must exercise stringsdict
        // selection, not simply reproduce a JSON translation dictionary.
        for language in ["de", "en"] {
            select(language)
            let en = language == "en"
            for count in [0, 1, 2, 21] {
                let number = String(count)
                equal(L10n.count("%lld Titel", count), number + (en ? (count == 1 ? " song" : " songs") : " Titel"), "\(language) song plural \(count)")
                equal(L10n.count("%lld Sekunden", count), number + (en ? (count == 1 ? " second" : " seconds") : (count == 1 ? " Sekunde" : " Sekunden")), "\(language) seconds plural \(count)")
                equal(L10n.count("%lld Minuten", count), number + (en ? (count == 1 ? " minute" : " minutes") : (count == 1 ? " Minute" : " Minuten")), "\(language) minutes plural \(count)")
            }
            // Real error templates contain object and integer substitutions.
            let errorKey = "Die Quelle konnte auf dem Mac nicht vollständig verarbeitet werden (%@)."
            let expected = en ? "The source could not be fully processed on the Mac (fixture_42)." : "Die Quelle konnte auf dem Mac nicht vollständig verarbeitet werden (fixture_42)."
            equal(L10n.format(errorKey, "fixture_42"), expected, "\(language) explicit error format")
            equal(L10n.text("Die Quelle konnte auf dem Mac nicht vollständig verarbeitet werden (fixture_42)."), expected, "\(language) stored interpolated error")
            let sourceError = "Die Quelle konnte auf dem Mac nicht vollständig verarbeitet werden (fixture_42)."
            let revokePrefix = "Widerruf nicht bestätigt. Der lokale Zugang bleibt für einen erneuten Versuch gespeichert. "
            let retrySuffix = " Prüfe auch die Auftragsliste; ein erneuter Versuch mit derselben Auswahl verwendet dieselbe Auftragsanfrage."
            let translatedPrefix = en ? "Revocation was not confirmed. Local credentials are kept so you can try again. " : revokePrefix
            let translatedSuffix = en ? " Also check the job list; retrying with the same selection reuses the same job request." : retrySuffix
            equal(L10n.text(revokePrefix + sourceError), translatedPrefix + expected, "\(language) revocation prefix and nested formatted error")
            equal(L10n.text(sourceError + retrySuffix), expected + translatedSuffix, "\(language) retry suffix and nested formatted error")
            let networkError = "Mac nicht erreichbar. Prüfe WLAN, lokalen Netzwerkzugriff und ob der Companion auf dem Mac läuft."
            let translatedNetworkError = en ? "Mac unreachable. Check Wi-Fi, local network access and whether the Companion is running on the Mac." : networkError
            equal(L10n.text(revokePrefix + networkError), translatedPrefix + translatedNetworkError, "\(language) revocation prefix and nested plain error")
            equal(L10n.text(networkError + retrySuffix), translatedNetworkError + translatedSuffix, "\(language) retry suffix and nested plain error")
            let nativeCases: [(Error, String)] = [
                (NSError(domain: "fixture", code: 42, userInfo: [NSLocalizedDescriptionKey: "OS-language message"]), "Der Vorgang konnte nicht abgeschlossen werden. Bitte versuche es erneut."),
                (NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue), "Keine Netzwerkverbindung. Prüfe dein Netzwerk und versuche es erneut."),
                (URLError(.notConnectedToInternet), "Keine Netzwerkverbindung. Prüfe dein Netzwerk und versuche es erneut."),
                (URLError(.timedOut), "Das Zeitlimit wurde erreicht. Versuche es erneut."),
                (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue), "Nicht genug freier Speicherplatz. Gib Speicher frei und versuche den Import erneut."),
                (FixtureError.appOwned, "Die Verarbeitung wurde abgebrochen.")
            ]
            for (error, source) in nativeCases {
                equal(L10n.error(error), source, "OS error normalized to stable source key")
                let translated: String
                switch source {
                case "Der Vorgang konnte nicht abgeschlossen werden. Bitte versuche es erneut.":
                    translated = "The operation could not be completed. Please try again."
                case "Keine Netzwerkverbindung. Prüfe dein Netzwerk und versuche es erneut.":
                    translated = "No network connection. Check your network and try again."
                case "Das Zeitlimit wurde erreicht. Versuche es erneut.":
                    translated = "The time limit was reached. Try again."
                case "Nicht genug freier Speicherplatz. Gib Speicher frei und versuche den Import erneut.":
                    translated = "Not enough free storage. Free up space and try importing again."
                default:
                    translated = "Processing was cancelled."
                }
                equal(L10n.text(L10n.error(error)), en ? translated : source, "\(language) normalized error rendering")
            }
            equal(L10n.text("Not a catalog key 🧪"), "Not a catalog key 🧪", "unknown key fallback")
            for sentinel in ["Unknown Artist", "Unbekannter Künstler"] {
                equal(MetadataText.artist(sentinel), en ? "Unknown Artist" : "Unbekannter Künstler", "artist sentinel \(sentinel)")
            }
            for sentinel in ["Unknown Album", "Unbekanntes Album"] {
                equal(MetadataText.album(sentinel), en ? "Unknown Album" : "Unbekanntes Album", "album sentinel \(sentinel)")
            }
            for name in ["", "Start", "General", "Björk", "Unknown Artist Live", "Mein Album 🧪"] {
                equal(MetadataText.artist(name), name, "real artist metadata preserved")
                equal(MetadataText.album(name), name, "real album metadata preserved")
            }
        }
        // A stored German message must follow a later language selection in the
        // same process; helper caches must not freeze the selected language.
        select("de")
        let stored = "Die Quelle konnte auf dem Mac nicht vollständig verarbeitet werden (fixture_42)."
        select("en")
        equal(L10n.text(stored), "The source could not be fully processed on the Mac (fixture_42).", "stored error after switch")
        select("de")
        equal(L10n.text(stored), stored, "stored error switch back")
        if !failures.isEmpty {
            let report = failures.map { "FAIL: \($0)" }.joined(separator: "\n") + "\n"
            FileHandle.standardError.write(Data(report.utf8))
            exit(1)
        }
        print("PASS: \(checks) compiled DE/EN localization assertions (plain lookups, plurals, errors, fallback, live switching)")
    }
}
