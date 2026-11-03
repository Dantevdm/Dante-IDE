import AppKit
import DanteKit
import SwiftUI

/// Help › Crash Reports…: the reports macOS wrote when Dante crashed, newest first, each with
/// where it stopped, Copy, Show in Finder and, when Dante's own code is the open project,
/// Ask the agent to fix it.
struct CrashReportsWindow: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        let theme = themeStore.theme
        CrashReportsView()
            .frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 620)
            .background(theme.ground.color)
            .environment(\.theme, theme)
            .tint(theme.accent.color)
            .preferredColorScheme(theme.colorScheme)
    }
}

struct CrashReportsView: View {
    @Environment(\.theme) private var theme
    @State private var reports: [AppCrash] = []
    @State private var loaded = false
    @State private var selection: URL?
    @State private var copied = false

    private var selected: AppCrash? { reports.first { $0.file == selection } ?? reports.first }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reports.isEmpty {
                VStack(spacing: 8) {
                    Image.symbol("checkmark.seal", side: 28).foregroundStyle(theme.green.color)
                    Text("No crash reports").font(.dante(size: 15, weight: .semibold))
                    Text("When Dante crashes, macOS writes a report and it shows here.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 280)
                    Rectangle().fill(theme.line.color).frame(width: 1)
                    if let report = selected { detail(report) }
                }
            }
        }
        .task {
            reports = await Task.detached { AppCrash.list() }.value
            loaded = true
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(reports) { report in
                    let isSelected = report.file == selected?.file
                    Button { selection = report.file } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.dante(size: 12.5, weight: .medium))
                            Text(report.headline)
                                .font(.dante(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.text3.color)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? theme.raised.color : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .background(theme.panel.color)
    }

    private func detail(_ report: AppCrash) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dante \(report.version) crashed").font(.dante(size: 17, weight: .semibold))
                    Text("\(report.date.formatted(date: .complete, time: .shortened)) · macOS \(report.os) · build \(report.build)")
                        .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                Text(Self.explanation(report))
                    .font(.dante(size: 13)).foregroundStyle(theme.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let session = Self.danteSession {
                        Button("Ask \(session.agentName) to fix it") { ask(session, about: report) }
                            .buttonStyle(DanteButtonStyle(primary: true))
                            .help("Sends the report to the agent in charge in the window with Dante's code")
                    }
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.summary, forType: .string)
                        copied = true
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("Copies the summary below, to paste into a bug report or a conversation")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.file]) }
                        .buttonStyle(DanteButtonStyle())
                }
                Eyebrow("\(report.exception) · \(report.termination)")
                if let message = report.message {
                    Text(message).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.red.color).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(report.frames.enumerated()), id: \.offset) { index, frame in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index)").foregroundStyle(theme.text3.color).frame(width: 20, alignment: .trailing)
                            Text(frame.image).foregroundStyle(frame.isDante ? theme.accent.color : theme.text3.color)
                                .frame(width: 170, alignment: .leading).lineLimit(1)
                            Text(frame.symbol).foregroundStyle(frame.isDante ? theme.text.color : theme.text2.color)
                                .lineLimit(2).textSelection(.enabled)
                        }
                        .font(.dante(size: 11.5, weight: frame.isDante ? .semibold : .regular, design: .monospaced))
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(frame.isDante ? theme.accent.color.opacity(0.08) : .clear)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.card.color))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line.color))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: report.file) { copied = false }
    }

    /// Where the crash happened, in a sentence.
    static func explanation(_ report: AppCrash) -> String {
        guard let frame = report.danteFrame else {
            return "It stopped inside \(report.frames.first?.image ?? "a system library"), with none of Dante's own code on the crashed thread, so it is most likely a bug in macOS."
        }
        let top = report.frames.first.map { $0.isDante ? "" : " It stopped in \($0.image), called from there." } ?? ""
        return "Dante's own code was running: \(frame.symbol).\(top)"
    }

    /// A window whose project is Dante's own code, where the agent can fix it.
    static var danteSession: Session? {
        let sessions = [ActiveProject.shared.session].compactMap { $0 } + Sessions.all
        return sessions.first { session in
            guard let root = session.workspace?.url else { return false }
            return FileManager.default.fileExists(atPath: root.appending(path: "Sources/DanteApp/DanteApp.swift").path)
        }
    }

    private func ask(_ session: Session, about report: AppCrash) {
        session.askClaude("""
        Dante crashed. Here's the crash report macOS wrote (top frames of the crashed thread). \
        Find the cause in the code and fix it; if it's a macOS bug, find a way around it.

        \(report.summary)
        """)
        NSApp.activate()
        session.window?.makeKeyAndOrderFront(nil)
    }
}
