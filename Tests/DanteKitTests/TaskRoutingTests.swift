import Foundation
import Testing
@testable import DanteKit

@Suite struct TaskRoutingTests {
    @Test func riskOutranksSimpleWording() {
        for text in ["Rename production database", "Fix the typo in authentication", "Change the label on the payment workflow", "Review the security architecture"] {
            let decision = TaskRouting.classify(text)
            #expect(decision.difficulty == .complex)
            #expect(decision.localKind == nil)
            #expect(decision.effort == "medium")
        }
    }

    @Test func routineAndUnknownWork() {
        #expect(TaskRouting.classify("Rename the Save button to Apply").effort == "low")
        for text in ["Fix it", "Carry on", "Make this faster", "Investigate these failures"] {
            #expect(TaskRouting.classify(text).difficulty == .standard)
            #expect(TaskRouting.classify(text).localKind == nil)
        }
    }

    @Test func localRequiresSelfContainedProse() {
        let text = "Reword this: Please join the team meeting tomorrow morning to discuss the next release."
        #expect(TaskRouting.classify("Summarize this: The team agreed to ship the next release after finishing the remaining tests.").localKind == .summary)
        #expect(TaskRouting.classify(text).localKind == .writing)
        #expect(TaskRouting.classify(text, hasAttachments: true).localKind == nil)
        #expect(TaskRouting.classify(text, hasInstructions: true).localKind == nil)
        for request in ["Rewrite this file: docs/README.md", "Reword this", "Summarize the project", "Reword this: hi", "Reword this project: review our application structure", "Summarize this: the previous conversation about the whole project", "Rewrite this function: func example() { return something }"] {
            #expect(TaskRouting.classify(request).localKind == nil)
        }
    }

    @Test func localSelectionRespectsMemoryAndCapabilities() {
        let models: [OllamaModel] = [
            .init(name: "qwen3:30b", size: 20_000),
            .init(name: "qwen3:4b", size: 2_000),
            .init(name: "qwen3:8b", size: 4_000),
            .init(name: "qwen3:cloud", size: 0),
            .init(name: "qwen3-vl:2b", size: 500),
            .init(name: "qwen3-embed:1b", size: 200),
        ]
        #expect(TaskRouting.localModel(for: .writing, installed: models, memory: 32_000) == "qwen3:4b")
        #expect(TaskRouting.localModel(for: .writing, installed: models, memory: 1_000) == nil)
        #expect(TaskRouting.localModel(for: .writing, installed: [.init(name: "unknown:1b", size: 100)], memory: 32_000) == nil)
    }

    @MainActor @Test func localTurnCanBeCancelledBeforeCloudStarts() {
        let session = ClaudeSession(root: URL(filePath: "/tmp"), executable: nil, systemPrompt: { "" })
        session.send("Reword this: Please join the team meeting tomorrow morning to discuss the next release.")
        #expect(session.state == .working)
        session.send("Now explain the code")
        #expect(session.queued.count == 1)
        session.interrupt()
        #expect(session.state == .idle)
        #expect(session.queued.count == 1)
        session.reset()
        #expect(session.queued.isEmpty)
    }
}
