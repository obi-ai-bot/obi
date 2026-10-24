import Foundation

/// Settings › Voice, the same on the iPhone and the Mac: the language Oby writes down what you
/// say in.
nonisolated enum VoiceSettings {
    /// The UserDefaults key of the dictation language: "system", or one of `languages`' ids.
    static let language = "voice.language"

    /// The languages Settings offers besides the device's own, by locale id.
    static let languages: [(id: String, name: String)] = [
        ("en-US", "English"), ("pt-BR", "Português (Brasil)"), ("pt-PT", "Português (Portugal)"),
    ]

    /// "iPhone language", "Mac language": the first choice, the device's own.
    static var systemName: String {
        #if os(macOS)
        "Mac language"
        #else
        "iPhone language"
        #endif
    }

    /// What dictation listens for: the language picked in Settings, else the device's own.
    static var locale: Locale { locale(UserDefaults.standard.string(forKey: language)) }

    static func locale(_ selected: String?) -> Locale {
        guard let selected, selected != "system" else { return .current }
        return Locale(identifier: selected)
    }

    /// "English", "Português (Brasil)": the language's name in itself, for a sentence like "This
    /// Mac can't write down English yet".
    static func name(_ locale: Locale) -> String {
        let id = locale.identifier(.bcp47)
        if let known = languages.first(where: { $0.id == id }) { return known.name }
        let code = locale.language.languageCode?.identifier ?? id
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? id
    }
}
