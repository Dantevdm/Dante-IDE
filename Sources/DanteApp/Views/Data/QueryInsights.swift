import AppKit
import DanteKit
import SwiftUI

/// Above an Explain's plan: the tables read end to end, the index for each, and Claude
/// to talk the plan through.
struct PlanStrip: View {
    @Environment(\.theme) private var theme
    let findings: [PlanFinding]
    let addIndex: (String) -> Void
    let explain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: findings.isEmpty ? "checkmark.circle" : "tortoise")
                    .foregroundStyle(findings.isEmpty ? theme.green.color : theme.amber.color)
                Text(findings.isEmpty ? "No full scans of filtered tables in this plan." : "Reads \(findings.count == 1 ? "a table" : "\(findings.count) tables") row by row to filter")
                    .font(.dante(size: 12, weight: .medium))
                    .foregroundStyle(theme.text.color)
                Spacer()
                Button(action: explain) { Label("Explain with Claude", systemImage: "sparkles") }
                    .buttonStyle(DanteButtonStyle())
            }
            ForEach(findings) { finding in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(finding.table) by \(finding.columns.joined(separator: ", "))")
                            .font(.dante(size: 12, design: .monospaced))
                            .foregroundStyle(theme.text.color)
                        Text(note(finding)).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    }
                    Spacer()
                    if let suggestion = finding.suggestion {
                        Button("Copy") { copy(suggestion + ";") }
                            .buttonStyle(.plain)
                            .font(.dante(size: 11.5))
                            .foregroundStyle(theme.text2.color)
                            .help(suggestion)
                        Button("Add Index…") { addIndex(suggestion + ";") }
                            .buttonStyle(DanteButtonStyle())
                            .help("Open \(suggestion) in a new query")
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.amber.color.opacity(findings.isEmpty ? 0 : 0.06))
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private func note(_ finding: PlanFinding) -> String {
        guard let rows = finding.rows else { return "An index on these columns lets it look rows up instead." }
        if finding.isSmall { return "Only \(DataFormat.count(rows)) rows now, so it’s cheap; the index matters as the table grows." }
        return "About \(DataFormat.count(rows)) rows read each time. An index lets it look rows up instead."
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// What a script's DDL would change, before it runs.
struct MigrationPreviewPanel: View {
    @Environment(\.theme) private var theme
    let changes: [SchemaChange]
    let connectionName: String
    let schemaKnown: Bool
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.rays").foregroundStyle(theme.accent.color)
                Text("What this changes in \(connectionName)").font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color)
                let warnings = changes.filter { $0.warning != nil }.count
                if warnings > 0 {
                    Text("\(warnings) to check").font(.dante(size: 11)).foregroundStyle(theme.amber.color)
                }
                Spacer()
                Button(action: review) { Label("Review with Claude", systemImage: "sparkles") }
                    .buttonStyle(DanteButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !schemaKnown {
                Text("Connect to check these against the tables that exist now.")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(changes) { change in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: symbol(change.kind))
                                .font(.dante(size: 11))
                                .foregroundStyle(change.isDestructive ? theme.red.color : theme.text3.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.summary).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                                if let warning = change.warning {
                                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                                        .font(.dante(size: 11))
                                        .foregroundStyle(change.isDestructive ? theme.red.color : theme.amber.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.ground.color)
    }

    private func symbol(_ kind: SchemaChange.Kind) -> String {
        switch kind {
        case .createTable: "tablecells.badge.ellipsis"
        case .dropTable, .emptyTable: "trash"
        case .renameTable, .renameColumn: "character.cursor.ibeam"
        case .addColumn: "plus.square"
        case .dropColumn: "minus.square"
        case .alterColumn: "arrow.triangle.2.circlepath"
        case .createIndex: "bolt"
        case .dropIndex: "bolt.slash"
        case .addConstraint, .dropConstraint: "link"
        case .other: "curlybraces"
        }
    }
}
