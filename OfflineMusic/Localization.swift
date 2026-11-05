import SwiftUI

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
        self == .system ? .current : Locale(identifier: rawValue)
    }

    var displayName: String {
        switch self {
        case .system: return "System"
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

struct AppSettingsView: View {
    @AppStorage("app.language") private var languageCode = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Sprache", selection: $languageCode) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
            } header: {
                Text("Allgemein")
            } footer: {
                Text("Die Sprache der App kann jederzeit geändert werden. Die Änderung wird sofort übernommen.")
            }
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
    }
}
