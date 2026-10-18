import DanteKit
import Testing

@Suite struct ReplyChoicesTests {
    @Test func readsANumberedListEndingInAQuestion() {
        let text = """
        Here's what I'd suggest.

        1. **Add a pure model** — a new file in Sources/DanteKit and a test beside it.
        2. **Add an area view** — Views in `Sources/DanteApp/Views/Areas/` built from
        the shared pieces.
        3. Build, test, bundle: the three commands.

        Which of these would you like me to write?
        """
        let choices = ReplyChoices.parse(text)
        #expect(choices?.options.map(\.title) == ["Add a pure model", "Add an area view", "Build, test, bundle"])
        #expect(choices?.question == "Which of these would you like me to write?")
        #expect(choices?.reply(choosing: [2]) == "2. Add an area view")
        #expect(choices?.reply(choosing: [1, 3]) == "1. Add a pure model\n3. Build, test, bundle")
    }

    @Test func boldBulletsCount() {
        let text = "Options:\n\n- **Rebase** onto main\n- **Merge** main in\n\nWhich do you prefer?"
        #expect(ReplyChoices.parse(text)?.options.map(\.title) == ["Rebase", "Merge"])
    }

    @Test func noQuestionOrPlainBulletsIsNotAChoice() {
        #expect(ReplyChoices.parse("Done:\n\n1. Fixed the parser\n2. Added tests\n\nAll green.") == nil)
        #expect(ReplyChoices.parse("Changes:\n\n- fixed a\n- fixed b\n\nAnything else?") == nil)
        #expect(ReplyChoices.parse("1. One\n3. Three\n\nWhich?") == nil)
    }

    @Test func takesTheLastListAndSkipsCode() {
        let text = """
        1. Old option
        2. Another

        Then later:

        ```
        1. not a list
        ```

        1. First real
        2. Second real
        Pick one?
        """
        #expect(ReplyChoices.parse(text)?.options.map(\.title) == ["First real", "Second real"])
    }
}
