import DanteKit
import Testing

@Suite struct ConstellationTests {
    func tool(_ id: String, _ name: String, _ input: JSONValue, running: Bool = true) -> ToolActivity {
        ToolActivity(id: id, name: name, input: input, status: running ? .running : .done)
    }

    func satellite(_ id: String) -> OrbSatellite {
        OrbSatellite(id: id, kind: .subagent("Explore"), color: RGBA(0x40C4FF), title: id)
    }

    @Test func runningSubAgentsAndDelegatedJobsBecomeSatellites() {
        let tools = [
            tool("a", "Task", ["subagent_type": "Explore", "description": "Find the routes"]),
            tool("b", "Bash", ["command": "ls"]),
            tool("c", "mcp__dante__delegate", ["kind": "summary", "prompt": "…"]),
            tool("d", "Agent", ["description": "Done already"], running: false),
        ]
        let satellites = OrbSatellite.running(in: tools)
        #expect(satellites.map(\.id) == ["a", "c"])
        #expect(satellites[0].kind == .subagent("Explore"))
        #expect(satellites[0].title == "Find the routes")
        #expect(satellites[1].kind == .local("summary"))
        #expect(satellites[1].title == "Reader")
    }

    @Test func satellitesSplitOffCircleAndMergeBack() {
        var constellation = Constellation()
        constellation.update([satellite("a")], at: 0)
        let budding = constellation.frames(at: 0.05, mainRadius: 0.46, satelliteRadius: 0.1).frames[0]
        #expect(budding.out < 0.1)
        #expect(budding.depth > 0.8) // starts on our side of the orb, so the split is seen
        let distance = { (f: Constellation.Frame) in (f.x * f.x + f.y * f.y).squareRoot() }
        #expect(distance(budding) < 0.46)

        var depths: [Double] = [], distances: [Double] = []
        for step in 0..<40 {
            let frame = constellation.frames(at: 2 + Double(step) * 0.5, mainRadius: 0.46, satelliteRadius: 0.1).frames[0]
            #expect(frame.out == 1)
            depths.append(frame.depth)
            distances.append(distance(frame))
        }
        // It passes behind the orb and in front of it, swinging well clear at the sides.
        #expect(depths.min()! < -0.5 && depths.max()! > 0.5)
        #expect(distances.max()! > 0.46 * 1.4)

        constellation.update([], at: 30)
        #expect(constellation.frames(at: 30.5, mainRadius: 0.46, satelliteRadius: 0.1).frames[0].out < 1)
        let after = constellation.frames(at: 30 + Constellation.merge, mainRadius: 0.46, satelliteRadius: 0.1)
        #expect(after.frames.isEmpty && after.merged == 1)
        #expect(constellation.isEmpty)
    }

    @Test func atMostSixAndSlotsAreReused() {
        var constellation = Constellation()
        constellation.update((0..<8).map { satellite("s\($0)") }, at: 0)
        #expect(constellation.frames(at: 1, mainRadius: 0.46, satelliteRadius: 0.1).frames.count == Constellation.limit)
        // One returning while it merges springs back out rather than starting again.
        constellation.update([], at: 2)
        constellation.update([satellite("s0")], at: 2.3)
        let frames = constellation.frames(at: 2 + Constellation.merge + 0.1, mainRadius: 0.46, satelliteRadius: 0.1)
        #expect(frames.frames.count == 1 && frames.merged == 5)
    }

    @Test func satellitesSayWhoHandedWhatToWhom() {
        let tools = [
            tool("a", "Task", ["subagent_type": "Explore", "description": "Find the parser"]),
            tool("b", "mcp__dante__delegate", ["kind": "summary", "why": "Summarise the failing test log.", "prompt": "…"]),
            tool("c", "mcp__dante__ask_claude", ["prompt": "Is this migration safe to run while the table is busy with writes from the queue workers? Here is the diff."]),
            tool("d", "Task", ["subagent_type": "general-purpose"]),
        ]
        let satellites = OrbSatellite.running(in: tools, lead: "Codex")
        #expect(satellites.allSatisfy { $0.lead == "Codex" })
        #expect(satellites[0].agent == "Explore")
        #expect(satellites[0].task == "Find the parser")
        #expect(satellites[1].task == "Summarise the failing test log")
        #expect(satellites[2].agent == "Claude")
        #expect(satellites[2].task.hasSuffix("…") && satellites[2].task.count <= 65)
        #expect(satellites[3].agent == "Sub-agent")
    }

    @Test func framesKeepTheirSlotAndSayWhenTheyreHeadingHome() {
        var constellation = Constellation()
        constellation.update([satellite("a"), satellite("b")], at: 0)
        constellation.update([satellite("b")], at: 2)
        let frames = constellation.frames(at: 2.5, mainRadius: 0.46, satelliteRadius: 0.1).frames
        #expect(frames.map(\.slot) == [0, 1])
        #expect(frames.map(\.returning) == [true, false])
        #expect(frames.map(\.satellite.id) == ["a", "b"])
    }
}
