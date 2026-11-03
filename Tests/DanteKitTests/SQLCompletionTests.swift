import Foundation
import Testing
@testable import DanteKit

struct SQLCompletionTests {
    let schema = DatabaseSchema(tables: [
        .init(schema: "public", name: "orders", columns: [
            .init(name: "id", type: "bigint", isPrimaryKey: true),
            .init(name: "customer_id", type: "bigint", references: ("customers", "id")),
            .init(name: "total", type: "numeric"),
        ]),
        .init(schema: "public", name: "customers", columns: [
            .init(name: "id", type: "bigint", isPrimaryKey: true),
            .init(name: "name", type: "text"),
        ]),
        .init(schema: "audit", name: "events", columns: [.init(name: "at", type: "timestamptz")]),
    ])

    func labels(_ sql: String, engine: DatabaseEngine = .postgres) -> [String] {
        let caret = (sql as NSString).range(of: "|").location
        let text = (sql as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return SQLCompletion.suggestions(in: text, at: caret, schema: schema, engine: engine)
            .sorted { $0.rank < $1.rank }.map(\.label)
    }

    @Test func tablesAfterFrom() {
        let found = labels("select * FROM |")
        #expect(found.prefix(3).contains("orders"))
        #expect(found.contains("audit.events"))
        #expect(found.contains("audit"))
        #expect(!found.contains("total"))
    }

    @Test func keywordsAfterATableName() {
        let found = labels("SELECT * FROM orders |")
        #expect(found.first == "WHERE")
        #expect(!found.contains("customers"))
    }

    @Test func columnsOfTheStatementsTables() {
        let found = labels("SELECT * FROM orders o WHERE |")
        #expect(found.contains("total"))
        #expect(!found.contains("name"))
        #expect(found.contains("AND"))
    }

    @Test func aliasAfterADotEvenWhenFromComesLater() {
        #expect(labels("SELECT o.| FROM orders o JOIN customers c ON c.id = o.customer_id") == ["id", "customer_id", "total"])
        #expect(labels("SELECT c.| FROM orders o JOIN customers AS c ON true") == ["id", "name"])
    }

    @Test func schemaQualifier() {
        #expect(labels("SELECT * FROM audit.|") == ["events"])
    }

    @Test func onlyTheStatementAtTheCaret() {
        let found = labels("SELECT * FROM customers; SELECT * FROM orders WHERE |")
        #expect(found.contains("total"))
        #expect(!found.contains("name"))
    }

    @Test func lowercaseKeywordsWhenTypingLowercase() {
        #expect(labels("SELECT * FROM orders wh|").contains("where"))
    }

    @Test func quotesOnlyWhenNeeded() {
        #expect(SQLCompletion.name("orders", .postgres) == "orders")
        #expect(SQLCompletion.name("OrderLines", .postgres) == "\"OrderLines\"")
        #expect(SQLCompletion.name("OrderLines", .mysql) == "OrderLines")
        #expect(SQLCompletion.name("order lines", .mysql) == "`order lines`")
    }
}
