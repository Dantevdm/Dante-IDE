import Foundation
import Testing
@testable import DanteKit

/// A table's schema from the repo's migrations, for the Map's inspector and copy menu.
struct MapSchemaTests {
    static let files: [String: String] = [
        "db/migration/V1__init.sql": """
        -- The first tables; a comment with a ; in it
        CREATE TABLE customers (
            id bigserial PRIMARY KEY,
            name text NOT NULL
        );
        create table orders (
            id bigint,
            customer_id bigint references customers(id),
            note text default 'a; b',
            primary key (id)
        );
        """,
        "db/migration/V10__drop.sql": "ALTER TABLE orders DROP COLUMN note;",
        "db/migration/V2__more.sql": """
        ALTER TABLE orders ADD COLUMN status varchar(20) NOT NULL, ADD COLUMN total numeric(10, 2);
        CREATE INDEX orders_status ON orders (status);
        CREATE FUNCTION touch() RETURNS trigger AS $$ BEGIN NEW.x := 1; RETURN NEW; END; $$ LANGUAGE plpgsql;
        """,
    ]

    @Test func migrationsAreAppliedInOrder() throws {
        let tables = SystemMap.schema(files: Array(Self.files.keys)) { Self.files[$0] }
        #expect(tables.map(\.name) == ["customers", "orders"])
        let orders = try #require(tables.last)
        // V2 adds, V10 drops (V10 after V2, not after V1).
        #expect(orders.columns.map(\.name) == ["id", "customer_id", "status", "total"])
        #expect(orders.columns[0].primaryKey && orders.columns[2].notNull && orders.columns[3].type == "numeric(10, 2)")
        #expect(orders.statements.count == 4)
        #expect(orders.ddl.hasPrefix("create table orders (") && orders.ddl.contains("CREATE INDEX orders_status ON orders (status);"))
        #expect(orders.file == "db/migration/V1__init.sql" && orders.line == 6)
        let customers = try #require(tables.first)
        #expect(customers.line == 2 && customers.columns[0].primaryKey)
        #expect(customers.referencedBy == [.init(table: "orders", column: "customer_id")])
        #expect(orders.select == "SELECT id, customer_id, status, total\nFROM orders\nLIMIT 100;")
        #expect(orders.markdown.contains("| customer_id | bigint | FK | customers |"))
        let er = SystemMap.mermaidER(tables)
        #expect(er.contains("numeric102 total") && er.contains("customers ||--o{ orders : \"customer_id\""))
    }
}

/// Suggestions for the database from its schema and the code's queries.
struct SchemaAdviceTests {
    static let files: [String: String] = [
        "db/V1__init.sql": """
        create table customers (id bigint primary key, email text unique, created timestamp);
        create table orders (
            id bigint primary key,
            customer_id bigint references customers(id),
            status text,
            total float
        );
        create table audit (what text, at timestamptz);
        create table lines (id bigint primary key, order_id bigint references orders(id));
        create index lines_order on lines (order_id);
        """,
        "api/src/main/java/shop/Order.java": "@Entity\n@Table(name = \"orders\")\npublic class Order {}",
        "api/src/main/java/shop/OrderRepository.java": """
        public interface OrderRepository extends JpaRepository<Order, Long> {
            List<Order> findByStatusOrderByIdDesc(String status);
            List<Order> findByCustomer(Customer customer);
        }
        """,
        "api/src/main/java/shop/Report.java": """
        class Report {
            void run() {
                var rows = jdbc.query("SELECT * FROM audit WHERE what = ?", mapper);
                for (Customer c : customers) {
                    var mine = orderRepository.findByCustomer(c);
                }
                jdbc.query("select id from customers c where c.email = ?", mapper);
            }
        }
        """,
    ]

    @Test func schemaAndCodeAdvice() {
        let tables = SystemMap.schema(files: Array(Self.files.keys)) { Self.files[$0] }
        #expect(tables.first { $0.name == "lines" }?.isIndexed(["order_id"]) == true)
        #expect(tables.first { $0.name == "customers" }?.isIndexed(["email"]) == true)
        let advice = SchemaAdvice.analyse(tables, files: Array(Self.files.keys)) { Self.files[$0] }
        let titles = advice.map(\.title)
        // Warnings first.
        #expect(advice.first?.weight == .warning)
        #expect(titles.contains("audit has no primary key"))
        #expect(titles.contains("orders.total holds money as float"))
        #expect(titles.contains("Index orders.customer_id"))
        #expect(!titles.contains("Index lines.order_id"))
        #expect(titles.contains("Index orders (status)"))
        #expect(titles.contains("Index audit (what)"))
        // customer_id is already advised as a foreign key, and email is unique.
        #expect(!titles.contains("Index orders (customer_id)") || titles.contains("Index orders.customer_id"))
        #expect(!titles.contains("Index customers (email)"))
        #expect(titles.contains("customers.created has no time zone"))
        #expect(titles.contains("SELECT * from audit"))
        #expect(advice.contains { $0.kind == .queryInLoop && $0.file?.hasSuffix("Report.java") == true && $0.line == 5 })
        #expect(advice.first { $0.title == "Index orders.customer_id" }?.fix == "CREATE INDEX orders_customer_id_idx ON orders (customer_id);")
    }
}
