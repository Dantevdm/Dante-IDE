import DanteKit
import SwiftUI

struct StatusBar: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 16) {
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
            }
            if let current = workspace.lifecycle.currentIndex {
                HStack(spacing: 5) {
                    StatusDot(color: theme.accent.color, size: 6)
                    Text("\(workspace.lifecycle.phases[current]) phase")
                }
            }
            Spacer()
            if let document = workspace.activeDocument {
                Text("Ln \(session.cursor.line), Col \(session.cursor.column)")
                Text(document.language.displayName)
                Text("UTF-8")
            }
            Text(themeStore.id.displayName)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11.5))
        .foregroundStyle(theme.text3.color)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }
}
