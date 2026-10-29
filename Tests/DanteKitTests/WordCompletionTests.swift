import Foundation
import Testing
@testable import DanteKit

struct WordCompletionTests {
    private let url = URL(filePath: "/home/me/shop/src/orders.ts")

    @Test func offersWordsDeclarationsAndKeywords() {
        let text = "const orderTotal = 1\nfunction orderLines(order) { return orderTotal + order.count }\nor"
        let here = DeclarationScanner.symbols(in: text, language: .typescript, url: url)
        let project = [CodeSymbol(name: "OrderService", kind: .type, container: nil, url: URL(filePath: "/home/me/shop/src/service.ts"),
                                  range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 12)))]
        let items = WordCompletion.suggestions(in: text, at: (text as NSString).length, keywords: ["or", "of", "return"], here: here, project: project)
        let labels = items.map(\.label)
        #expect(labels.contains("orderTotal"))
        #expect(labels.contains("order"))
        #expect(labels.contains("OrderService"))
        #expect(!labels.contains("or"), "what's typed isn't offered back")
        #expect(!labels.contains("return"), "keywords must match the prefix")
        #expect(items.first { $0.label == "OrderService" }?.detail == "service.ts")
        #expect(items.first { $0.label == "orderLines" }?.source == .here)
    }

    @Test func matchesAbbreviationsByFirstLetter() {
        #expect(WordCompletion.matches("usrSvc", "userService"))
        #expect(WordCompletion.matches("us", "UserService"))
        #expect(!WordCompletion.matches("svc", "userService"))
        #expect(!WordCompletion.matches("ab", "ba"))
    }

    @Test func nothingAfterADigitOrWithoutAPrefix() {
        #expect(WordCompletion.suggestions(in: "value 12", at: 8).isEmpty)
        #expect(WordCompletion.suggestions(in: "value ", at: 6).isEmpty)
    }

    @Test func theWordBeingTypedOnlyCountsWhenItAppearsElsewhere() {
        let text = "customer customer cust"
        let items = WordCompletion.suggestions(in: text, at: (text as NSString).length)
        #expect(items.map(\.label) == ["customer"])
        #expect(items.first?.count == 2)
    }
}
