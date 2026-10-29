import DanteKit
import SwiftUI

/// Code no test names, most untested first, with Write tests for each file.
struct UntestedView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let gaps: TestGaps?
    let hasTests: Bool
    var showsHeader = true
    /// Only the first few files of logic, as plain rows.
    var limit: Int? = nil

    @State private var showsInterface = false
    @State private var expanded: Set<String> = []

    var body: some View {
        if let gaps {
            let logic = gaps.files.filter { !$0.isInterface && !$0.untested.isEmpty }
            let interface = gaps.files.filter { $0.isInterface && !$0.untested.isEmpty }
            if showsHeader { header(gaps) }
            if let limit {
                rows(Array((logic + interface).prefix(limit)))
            } else if logic.isEmpty && interface.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "Every function is named in a test") { EmptyView() }
            } else {
                Card("Logic") {
                    Text("\(logic.count) file\(logic.count == 1 ? "" : "s"), most untested first").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                } content: {
                    rows(logic)
                }
                if !interface.isEmpty {
                    Card("Views and screens") {
                        LinkButton(showsInterface ? "Hide" : "Show \(interface.count)") { showsInterface.toggle() }
                    } content: {
                        if showsInterface {
                            rows(interface)
                        } else {
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func header(_ gaps: TestGaps) -> some View {
        let tested = gaps.declarations - gaps.untestedCount
        let fraction = gaps.declarations == 0 ? 1 : Double(tested) / Double(gaps.declarations)
        return HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(gaps.untestedCount) of \(gaps.declarations) functions and types aren’t named in any test")
                    .font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text.color)
                ProgressView(value: fraction).tint(theme.green.color).frame(maxWidth: 360)
            }
            Spacer()
            Button {
                session.askClaude(gaps.prompt())
            } label: { ClaudeLabel("Ask Claude what matters most") }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(gaps.untestedCount == 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }

    private func rows(_ files: [UntestedFile]) -> some View {
        RowList(data: files, padding: 8) { file in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button { session.open(file: workspace.url.appending(path: file.path)) } label: {
                        HStack(spacing: 6) {
                            Text((file.path as NSString).lastPathComponent).font(.dante(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color)
                            Text((file.path as NSString).deletingLastPathComponent).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 6)
                    if file.hasTestFile { Chip(text: "has a test file") }
                    Text("\(file.untested.count) of \(file.declared.count) untested · \(file.lines) lines")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    Button("Write tests") {
                        session.askClaude("Write tests for \(file.path). Nothing tests these yet: \(file.untested.prefix(15).joined(separator: ", ")). \(hasTests ? "Follow the project's existing test style and runner." : "The project has no tests yet: pick the standard runner for this language and set test.command in .dante/project.yaml if Dante can't detect it.") Start with the behaviour most likely to break, and show me each file before writing it.")
                    }
                    .buttonStyle(DanteButtonStyle())
                }
                let names = expanded.contains(file.id) ? file.untested : Array(file.untested.prefix(8))
                FlowLayout(spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        Text(name).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if file.untested.count > 8 {
                        LinkButton(expanded.contains(file.id) ? "fewer" : "+\(file.untested.count - 8) more") {
                            if expanded.contains(file.id) { expanded.remove(file.id) } else { expanded.insert(file.id) }
                        }
                    }
                }
            }
        }
    }
}
