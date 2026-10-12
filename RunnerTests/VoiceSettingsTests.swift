import Foundation
import Testing
@testable import ObyShared

/// Settings › Voice, the same on the iPhone and the Mac: what dictation listens for.
struct VoiceSettingsTests {
    @Test func theDevicesLanguageUntilOneIsPicked() {
        #expect(VoiceSettings.locale(nil) == .current)
        #expect(VoiceSettings.locale("system") == .current)
        #expect(VoiceSettings.locale("pt-BR").identifier(.bcp47) == "pt-BR")
    }

    @Test func everyChoiceIsALocaleWithItsOwnName() {
        for language in VoiceSettings.languages {
            #expect(VoiceSettings.locale(language.id).identifier(.bcp47) == language.id)
            #expect(VoiceSettings.name(VoiceSettings.locale(language.id)) == language.name)
        }
        #expect(VoiceSettings.name(Locale(identifier: "fr-FR")) == "Français")
    }
}
