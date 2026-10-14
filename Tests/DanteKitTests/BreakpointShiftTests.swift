@testable import DanteKit
import Foundation
import Testing

struct BreakpointShiftTests {
    let text = "a\nb\nc\nd\n" as NSString // lines 1-4: a, b, c, d

    func shift(_ lines: Set<Int>, _ location: Int, _ length: Int, _ replacement: String) -> Set<Int> {
        BreakpointShift.apply(lines, in: text, replacing: NSRange(location: location, length: length), with: replacement)
    }

    @Test func movesWithLinesAddedOrRemovedAbove() {
        #expect(shift([3], 0, 0, "x\ny\n") == [5])        // two lines added at the top
        #expect(shift([3], 2, 0, "\n") == [4])            // Enter at the start of b
        #expect(shift([3], 1, 0, "\n") == [4])            // Enter at the end of a
        #expect(shift([2, 4], 0, 2, "") == [1, 3])        // line a deleted
    }

    @Test func staysWhenTheEditIsOnOrAfterItsLine() {
        #expect(shift([2], 3, 0, "zz") == [2])            // typing inside b
        #expect(shift([2], 2, 0, "zz") == [2])            // typing at the start of b
        #expect(shift([2], 3, 0, "\n") == [2])            // Enter at the end of b
        #expect(shift([2], 6, 2, "") == [2])              // line d deleted, below
    }

    @Test func goesWithItsDeletedLine() {
        #expect(shift([2, 3], 2, 2, "") == [2])           // b deleted: c moves up to 2
        #expect(shift([2, 3], 2, 4, "") == [])            // b and c deleted: d becomes line 2, without one
        #expect(shift([3], 3, 2, "") == [2])              // b's newline and c's text: c's tail joins b
        #expect(shift([2], 1, 2, "") == [1])              // a's newline and b's text: b joins a
    }

    @Test func leavesThingsAloneWithoutBreakpoints() {
        #expect(shift([], 0, 0, "\n").isEmpty)
        #expect(shift([9], 0, 0, "\n") == [10])           // past the end still shifts (stale lines are harmless)
    }
}
