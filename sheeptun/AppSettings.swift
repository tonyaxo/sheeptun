import Foundation
import Combine

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt64

    // Right Option key (keyCode 61), no additional modifiers required
    static let defaultConfig = HotkeyConfig(keyCode: 61, modifierFlags: 0)

    var displayString: String {
        keyCode == 61 ? "⌥ Right Option" : "Custom (keyCode \(keyCode))"
    }
}

final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var hotkey: HotkeyConfig {
        didSet { saveHotkey() }
    }

    @Published var autoInsertText: Bool {
        didSet { defaults.set(autoInsertText, forKey: Keys.autoInsert) }
    }

    @Published var locale: Locale {
        didSet { defaults.set(locale.identifier, forKey: Keys.locale) }
    }

    // nil = filter disabled; model decides script per-token (best for mixed-language speech)
    @Published var languageFilterCode: String? {
        didSet { defaults.set(languageFilterCode, forKey: Keys.languageFilter) }
    }

    static let availableLanguageFilters: [(code: String, name: String)] = [
        ("ru", "Русский"),
        ("uk", "Українська"),
        ("be", "Беларуская"),
        ("bg", "Български"),
        ("sr", "Српски"),
        ("el", "Ελληνικά"),
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("it", "Italiano"),
        ("pt", "Português"),
        ("ro", "Română"),
        ("nl", "Nederlands"),
        ("da", "Dansk"),
        ("sv", "Svenska"),
        ("fi", "Suomi"),
        ("hu", "Magyar"),
        ("et", "Eesti"),
        ("lv", "Latviešu"),
        ("lt", "Lietuvių"),
        ("mt", "Malti"),
        ("pl", "Polski"),
        ("cs", "Čeština"),
        ("sk", "Slovenčina"),
        ("sl", "Slovenščina"),
        ("hr", "Hrvatski"),
        ("bs", "Bosanski"),
    ]

    private enum Keys {
        static let hotkey = "hotkey"
        static let autoInsert = "autoInsertText"
        static let locale = "locale"
        static let languageFilter = "languageFilterCode"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.hotkey),
           let decoded = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            hotkey = decoded
        } else {
            hotkey = .defaultConfig
        }
        autoInsertText = defaults.object(forKey: Keys.autoInsert) as? Bool ?? true
        let localeId = defaults.string(forKey: Keys.locale) ?? "ru-RU"
        locale = Locale(identifier: localeId)
        languageFilterCode = defaults.object(forKey: Keys.languageFilter) as? String
    }

    private func saveHotkey() {
        if let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: Keys.hotkey)
        }
    }
}
