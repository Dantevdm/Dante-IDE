import Testing
@testable import DanteKit

struct BrokenRunLinesTests {
    /// go test prints a package's compile errors first and only a bare FAIL at the end.
    let goOutput = [
        "# example.com/shop/orders",
        "orders/orders.go:12:5: undefined: Order",
        "FAIL\texample.com/shop/orders [build failed]",
    ] + (1...40).flatMap { i in ["=== RUN   TestCalculate\(i)", "--- PASS: TestCalculate\(i) (0.00s)", "PASS", "ok  \texample.com/shop/m\(i)\t0.4s"] } + ["FAIL"]

    @Test func keepsTheErrorFromTheStartAndTheEnd() {
        let picked = BrokenRunLines.pick(goOutput)
        #expect(picked.first == "# example.com/shop/orders")
        #expect(picked.contains("orders/orders.go:12:5: undefined: Order"))
        #expect(picked.contains("…"))
        #expect(picked.last == "FAIL")
        #expect(picked.count < 25)
    }

    @Test func saysWhatFailed() {
        #expect(BrokenRunLines.reason(in: BrokenRunLines.pick(goOutput)) == "shop/orders didn’t build")
        #expect(BrokenRunLines.reason(in: ["panic: runtime error: index out of range", "FAIL"]) == "A test panicked, so its package stopped")
        #expect(BrokenRunLines.reason(in: ["ModuleNotFoundError: No module named 'shop'"]) == "Something the tests import is missing")
        #expect(BrokenRunLines.reason(in: ["FAIL"]) == nil)
    }

    @Test func passingLinesAreNotTheReason() {
        #expect(!BrokenRunLines.explains("--- PASS: TestErrorPaths (0.00s)"))
        #expect(!BrokenRunLines.explains("ok  \texample.com/shop/errors\t0.4s"))
        #expect(BrokenRunLines.explains("npm ERR! missing script: test"))
    }

    @Test func aShortOutputIsKeptWhole() {
        let lines = ["Starting", "Error: cannot connect", "done"]
        #expect(BrokenRunLines.pick(lines) == lines)
    }
}
