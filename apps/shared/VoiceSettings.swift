import Foundation
#if os(iOS) || os(macOS)
import AVFoundation
import NaturalLanguage
#endif

/// Settings › Voice, the same on the iPhone and the Mac: the language Oby writes down what you
/// say in, and the voice it reads its replies with.
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

    #if os(iOS) || os(macOS)
    /// The voice a reply is read with. Replies can be in another language than the request, so it
    /// goes by the reply itself, with the device's language for ambiguous text, never by the
    /// dictation setting: the best installed voice for that language (premium, then enhanced, the
    /// exact locale first), else the system's own.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        let fallback = AVSpeechSynthesisVoice(language: detected)
        let locale = fallback?.language ?? detected
        let language = locale.split(separator: "-").first.map(String.init) ?? detected
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice)
                && ($0.quality == .enhanced || $0.quality == .premium)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            (voice.language == locale ? 0 : 1, voice.quality == .premium ? 0 : 1)
        }
        return voices.min { rank($0) < rank($1) } ?? fallback
    }
    #endif
}
