import Testing
@testable import SaiityLLM

// Move into the main-owned test target only after applying the pending vendor
// patches. These fixtures do not load a model, inspect private text or tokenize.
@Suite struct Gemma4TemplateTests {
    @Test("Gemma 4 framing matches the pinned chat renderer without a duplicate literal BOS")
    func systemHistoryAndUnicode() {
        let template = Template.gemma4("Preserve names and numbers.")
        let history: [Chat] = [(.user, "cafe\u{301} 字幕"), (.bot, "مرحبا 👩🏽‍💻")]
        let actual = template.preprocess("Send invoice 42.", history, .none)
        let expected = "<|turn>system\nPreserve names and numbers.<turn|>\n"
            + "<|turn>user\ncafe\u{301} 字幕<turn|>\n"
            + "<|turn>model\nمرحبا 👩🏽‍💻<turn|>\n"
            + "<|turn>user\nSend invoice 42.<turn|>\n<|turn>model\n"

        #expect(actual == expected)
        #expect(template.prefix.isEmpty)
        #expect(!actual.contains("<bos>"))
        #expect(template.stopSequence == "<turn|>")
    }

    @Test("Gemma 4 with no system message preserves exact user whitespace")
    func noSystemMessage() {
        let template = Template.gemma4()
        #expect(template.preprocess("  Hello\n", [], .none)
            == "<|turn>user\n  Hello\n<turn|>\n<|turn>model\n")
        #expect(template.systemPrompt == nil)
    }

    @Test("Gemma 4 does not fabricate legacy think tags for generic thinking modes",
          arguments: [ThinkingMode.none, .suppressed, .enabled])
    func framingDoesNotInventThinkingTokens(mode: ThinkingMode) {
        let template = Template.gemma4()
        #expect(template.preprocess("Hello", [], mode)
            == "<|turn>user\nHello<turn|>\n<|turn>model\n")
        #expect(template.thinkingStart == nil)
        #expect(template.thinkingEnd == nil)
        // This checks the input framing only. It does not prove that generated
        // reasoning-channel text is suppressed by the native wrapper.
    }

    @Test("official Gemma 4 GGUF filenames select the version-specific template",
          arguments: ["gemma-4-E2B_q4_0-it.gguf", "gemma-4-E4B_q4_0-it.gguf",
                      "google/Gemma-4-E2B-it", "Gemma 4 E4B", "gemma_4_E2B"])
    func versionedIdentifiers(identifier: String) {
        let context = TemplateResolutionContext(fileName: identifier)
        #expect(TemplateResolver.inferFamily(from: context) == .gemma4)
        let resolved = TemplateResolver.resolve(systemPrompt: "Keep facts.", context: context)
        #expect(resolved.preprocess("Hello", [], .none)
            == "<|turn>system\nKeep facts.<turn|>\n<|turn>user\nHello<turn|>\n<|turn>model\n")
    }

    @Test("GGUF architecture metadata wins over a misleading local filename")
    func architectureMetadata() {
        let context = TemplateResolutionContext(fileName: "gemma-3-1b-it.gguf",
            metadata: ["general.architecture": "gemma4", "general.name": "Imported model"])
        #expect(TemplateResolver.inferFamily(from: context) == .gemma4)
    }

    @Test("generic Gemma architecture can use the metadata name's explicit version")
    func genericArchitectureWithVersionedName() {
        let context = TemplateResolutionContext(fileName: "renamed.gguf",
            metadata: ["general.architecture": "gemma", "general.name": "Gemma 4 E2B"])
        #expect(TemplateResolver.inferFamily(from: context) == .gemma4)
    }

    @Test("explicit older architecture is not overridden by the model name")
    func olderArchitectureRemainsAuthoritative() {
        let context = TemplateResolutionContext(fileName: "gemma-4-E4B_q4_0-it.gguf",
            metadata: ["general.architecture": "gemma3", "general.name": "Gemma 4 E4B"])
        #expect(TemplateResolver.inferFamily(from: context) == .gemma)
    }

    @Test("Gemma 4 turn markers take priority over generic thinking keywords")
    func versionedChatHint() {
        let context = TemplateResolutionContext(fileName: "renamed.gguf",
            chatTemplateHint: "enable_thinking <|turn>user\ntext<turn|>\n<|turn>model\n")
        #expect(TemplateResolver.inferFamily(from: context) == .gemma4)
    }

    @Test("explicit template override remains authoritative")
    func explicitOverride() {
        let context = TemplateResolutionContext(metadata: ["general.architecture": "gemma4"])
        let resolved = TemplateResolver.resolve(explicitTemplate: .chatML("Override"), context: context)
        #expect(resolved.preprocess("Hello", [], .none)
            == "<|im_start|>system\nOverride<|im_end|>\n<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n")
    }

    @Test("older Gemma and a different future version retain legacy framing",
          arguments: ["gemma", "gemma2", "gemma3", "gemma-3-1b-it-Q4_K_M.gguf", "gemma40"])
    func legacyGemmaStillResolves(identifier: String) {
        #expect(TemplateResolver.inferFamily(from: .init(modelName: identifier)) == .gemma)
        #expect(Template.gemma.preprocess("Hello", [], .none)
            == "<start_of_turn>user\nHello<end_of_turn>\n<start_of_turn>model\n")
    }
}
