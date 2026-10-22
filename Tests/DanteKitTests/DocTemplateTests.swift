import Foundation
@testable import DanteKit
import Testing

@Suite struct DocTemplateTests {
    let existing = [
        "README.md", "docs/setup.md",
        "docs/decisions/0001-use-postgres.md", "docs/decisions/0007-one-alb.md", "docs/decisions/README.md",
        "infrastructure/portal-alb-stack/documentation/README.md",
    ]

    @Test func newDocsGoWhereTheProjectKeepsThem() {
        #expect(DocTemplate.decision.defaultFolder(existing: existing) == "docs/decisions")
        #expect(DocTemplate.decision.defaultFolder(existing: [".dante/decisions/0001-x.md"]) == ".dante/decisions")
        #expect(DocTemplate.runbook.defaultFolder(existing: existing) == "docs/runbooks")
        #expect(DocTemplate.readme.defaultFolder(existing: []) == "")
        #expect(DocTemplate.readme.defaultFolder(existing: existing) == "docs")
    }

    @Test func namesFilesFromTheTitle() {
        #expect(DocTemplate.decision.path(title: "Share one certificate", folder: "docs/decisions", existing: existing)
                == "docs/decisions/0008-share-one-certificate.md")
        #expect(DocTemplate.howTo.path(title: "Setup", folder: "docs", existing: existing) == "docs/setup-2.md")
        #expect(DocTemplate.document.path(title: "", folder: "", existing: []) == "untitled.md")
        // A folder has one README.
        #expect(DocTemplate.readme.path(title: "README", folder: "infrastructure/portal-alb-stack/documentation", existing: existing) == nil)
        #expect(DocTemplate.readme.path(title: "README", folder: "infrastructure/portal-ecr-stack", existing: existing)
                == "infrastructure/portal-ecr-stack/README.md")
    }

    @Test func templatesStartWithTheirOutline() {
        let decision = DocTemplate.decision.body(title: "One ALB", project: "OM", folder: "docs/decisions",
                                                 date: Date(timeIntervalSince1970: 0), number: 8)
        #expect(decision.hasPrefix("# 0008. One ALB\n"))
        #expect(decision.contains("- Date: 1970-01-01") && decision.contains("## Consequences"))
        #expect(DocTemplate.readme.body(title: "README", project: "OM", folder: "apps/hub").hasPrefix("# hub\n"))
        // The architecture outline's picture is a diagram Dante draws.
        let architecture = DocTemplate.architecture.body(title: "Architecture", project: "OM", folder: "docs")
        let mermaid = MarkdownDocument(architecture).blocks.compactMap { block -> String? in
            if case .code(let text, language: "mermaid") = block { text } else { nil }
        }
        #expect(mermaid.count == 1)
        guard case .flowchart(let chart) = Mermaid.parse(mermaid[0]) else { Issue.record("not a flowchart"); return }
        #expect(chart.nodes.count == 2)
        for template in DocTemplate.allCases {
            #expect(!template.body(title: "T", project: "P", folder: "").isEmpty)
        }
    }

    @Test func theAgentIsAskedToFillTheOutlineFromTheCode() {
        let request = DocTemplate.runbook.draftRequest(path: "docs/runbooks/restart.md", title: "Restart", about: "the hub service")
        #expect(request.contains("docs/runbooks/restart.md") && request.contains("the hub service"))
        #expect(request.contains("Don't invent"))
    }

    @Test func offersTheFoldersThatHoldDocs() {
        let library = DocLibrary(paths: existing)
        let folders = DocTemplate.folders(for: .runbook, library: library, existing: existing)
        #expect(folders.prefix(3) == ["docs/runbooks", "docs", ""])
        #expect(folders.contains("docs/decisions") && folders.contains("infrastructure/portal-alb-stack/documentation"))
        #expect(Set(folders).count == folders.count)
    }
}
