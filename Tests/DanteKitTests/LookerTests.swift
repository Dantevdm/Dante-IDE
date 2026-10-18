import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DanteKit

@Suite struct LookerTests {
    private let gb: Int64 = 1_000_000_000
    private let memory: UInt64 = 24_000_000_000

    @Test func picksTheBestCapableModelThatFits() {
        let installed = [
            OllamaModel(name: "llava:latest", size: 4 * gb),
            OllamaModel(name: "granite3.2-vision:2b", size: 2 * gb),
            OllamaModel(name: "qwen2.5vl:32b", size: 21 * gb),
            OllamaModel(name: "qwen3-vl:235b-cloud"),
            OllamaModel(name: "gemma3:12b", size: 8 * gb),
        ]
        #expect(Looker.model(installed: installed, memory: memory) == "gemma3:12b")
        let withQwen = installed + [OllamaModel(name: "qwen3-vl:8b", size: 6 * gb)]
        #expect(Looker.model(installed: withQwen, memory: memory) == "qwen3-vl:8b")
        #expect(Looker.model(installed: withQwen, memory: memory, chosen: "gemma3:12b") == "gemma3:12b")
    }

    @Test func weakOrOversizedModelsAreExplained() {
        let installed = [OllamaModel(name: "llava:latest", size: 4 * gb), OllamaModel(name: "qwen2.5vl:32b", size: 21 * gb)]
        #expect(Looker.model(installed: installed, memory: memory) == nil)
        let reason = Looker.missingReason(installed: installed, memory: memory)
        #expect(reason.contains("ollama pull qwen3-vl:8b"))
        #expect(reason.contains("qwen2.5vl:32b is too big"))
        #expect(reason.contains("llava:latest describes things"))
    }

    @Test func largeImagesAreScaledDown() throws {
        let context = try #require(CGContext(data: nil, width: 3000, height: 1800, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1800))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let prepared = try #require(Data(base64Encoded: try Looker.prepare(data as Data)))
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == Looker.maxSide)
        #expect(throws: Ollama.Failure.self) { try Looker.prepare(Data("not an image".utf8)) }
    }

    @Test func theRequestCarriesTheImageAndTheBrief() throws {
        let body = try #require(JSONValue(line: String(decoding: Ollama.lookBody(model: "qwen3-vl:8b", images: ["AAAA"], question: "What's the error?", maxTokens: 100), as: UTF8.self)))
        #expect(body["messages"]?.array?.last?["images"]?.array?.first?.string == "AAAA")
        #expect(body["messages"]?.array?.first?["content"]?.string?.contains("Quote text exactly") == true)
        #expect(body["think"]?.bool == false)
    }

    @Test func lookIsListedOnlyWithAModelAndRecordsTheJob() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "looker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = AgentLedger(url: folder.appending(path: "agents.jsonl"))
        var server = DelegateServer(project: "app", ledger: ledger, models: { [] }) { _, _ in ("m", OllamaReply(text: "")) }
        server.requester = "codex"
        server.look = { _, path, question in OllamaReply(text: "The banner says: Payment failed. More below.", seconds: 2) }

        server.lookerModel = { nil }
        let without = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? ""
        #expect(!without.contains(#""name":"look""#))
        let refused = await server.call("look", arguments: ["image": "shot.png", "question": "What's wrong?"])
        #expect(refused["isError"]?.bool == true)

        server.lookerModel = { "qwen3-vl:8b" }
        let with = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#) ?? ""
        #expect(with.contains(#""name":"look""#))
        let reply = await server.call("look", arguments: ["image": "shot.png", "question": "What's wrong?", "why": "see the checkout error"])
        #expect(reply["content"]?.array?.first?["text"]?.string?.contains("Payment failed") == true)

        let jobs = ledger.jobs()
        #expect(jobs.last?.kind == Looker.kind)
        #expect(jobs.last?.why == "see the checkout error")
        #expect(jobs.last.map(AgentStats.agent(of:)) == "Looker")
        #expect(AgentDigest(jobs).models.first { $0.name == "qwen3-vl:8b" }?.work.contains("reading screenshots") == true)
    }
}
