import Testing

@testable import sAiity

@Suite struct DictationMenuTests {
    @Test("captions and dictation translation entries keep separate scope and recents")
    func scopesDoNotShareTargets() {
        let captions = TranslationMenuModel.entries(
            scope: .captions,
            currentTarget: "de",
            recentTargets: ["fr"],
            preferredLanguages: ["ja"],
            fallbackLanguages: ["en"])
        let dictation = TranslationMenuModel.entries(
            scope: .dictation,
            currentTarget: "ja",
            recentTargets: ["zh"],
            preferredLanguages: ["de"],
            fallbackLanguages: ["en"])

        #expect(captions.map(\.selection) == [
            TranslationMenuSelection(scope: .captions, code: nil),
            TranslationMenuSelection(scope: .captions, code: "de"),
            TranslationMenuSelection(scope: .captions, code: "fr"),
            TranslationMenuSelection(scope: .captions, code: "ja"),
            TranslationMenuSelection(scope: .captions, code: "en")
        ])
        #expect(dictation.map(\.selection) == [
            TranslationMenuSelection(scope: .dictation, code: nil),
            TranslationMenuSelection(scope: .dictation, code: "ja"),
            TranslationMenuSelection(scope: .dictation, code: "zh"),
            TranslationMenuSelection(scope: .dictation, code: "de"),
            TranslationMenuSelection(scope: .dictation, code: "en")
        ])
        #expect(captions.filter(\.isSelected).map(\.selection.code) == ["de"])
        #expect(dictation.filter(\.isSelected).map(\.selection.code) == ["ja"])
    }
}
