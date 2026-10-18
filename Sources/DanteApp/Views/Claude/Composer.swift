import AppKit
import DanteKit
import SwiftUI
import UniformTypeIdentifiers

/// The message box under the conversation. Return sends; ⌥Return adds a line. Files can
/// be attached with the paperclip, by dropping them on the panel, or by pasting.
struct Composer: View {
    @Environment(\.theme) private var theme
    let session: Session
    let claude: ClaudeSession
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// The highlighted row in the @ or / list.
    @State private var picked = 0
    /// The token the list was dismissed for with Esc, so it stays closed until the next one.
    @State private var dismissed: String?
    @State private var skills: [ClaudeSkill] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let token = openToken, !suggestions(for: token).isEmpty {
                SuggestionList(rows: suggestions(for: token), picked: min(picked, suggestions(for: token).count - 1)) { index in
                    choose(index, for: token)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
            if !session.claudeAttachments.isEmpty || session.attachmentsLoading > 0 {
                FlowLayout(spacing: 5) {
                    ForEach(session.claudeAttachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            session.claudeAttachments.removeAll { $0.id == attachment.id }
                        }
                    }
                    if session.attachmentsLoading > 0 {
                        ProgressView().controlSize(.small).padding(.horizontal, 4)
                    }
                }
                .padding(.top, 2)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip").font(.dante(size: 12))
                        .frame(width: 20, height: 24)
                        .foregroundStyle(theme.text3.color)
                }
                .buttonStyle(.plain)
                .disabled(isUnavailable)
                .help("Attach files: images, PDFs, documents or code. You can also drop or paste them.")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.dante(size: 12.5))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .escape]) { press in
                        guard let token = openToken else { return .ignored }
                        let count = suggestions(for: token).count
                        guard count > 0 else { return .ignored }
                        switch press.key {
                        case .upArrow: picked = (min(picked, count - 1) + count - 1) % count
                        case .downArrow: picked = (min(picked, count - 1) + 1) % count
                        case .escape: dismissed = draft
                        default: choose(min(picked, count - 1), for: token)
                        }
                        return .handled
                    }
                    .onChange(of: draft) { picked = 0 }
                    .disabled(isUnavailable)
                    .padding(.vertical, 2)

                if claude.state == .working {
                    Button(action: claude.interrupt) {
                        Image(systemName: "stop.fill").font(.dante(size: 9))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(theme.text.color)
                            .background(Circle().fill(theme.raised.color))
                            .overlay(Circle().strokeBorder(theme.line2.color))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.dante(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(canSend ? theme.onAccent.color : theme.text3.color)
                            .background(Circle().fill(canSend ? theme.accent.color : theme.raised.color))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (↩)")
                }
            }
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.card.color))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(focused ? theme.accentLine.color : theme.line2.color)
            )

            ClaudeFooter(session: session, claude: claude)
        }
        .padding(12)
        .onChange(of: session.claudeFocusRequest) { focused = true }
        .task(id: session.workspace?.revision) {
            if let root = session.workspace?.url { skills = ClaudeSkills.load(root: root) }
        }
        .background(PasteInterceptor(isActive: focused) { pasteAttachments() })
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files for Claude to look at"
        panel.prompt = "Attach"
        if let root = session.workspace?.url { panel.directoryURL = root }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await session.attach(urls) }
    }

    /// Files or an image on the pasteboard become attachments; text pastes as usual.
    private func pasteAttachments() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            Task { await session.attach(urls) }
            return true
        }
        if pasteboard.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            session.attachImage(png)
            return true
        }
        return false
    }

    private var isUnavailable: Bool {
        if case .unavailable = claude.state { true } else { false }
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.claudeAttachments.isEmpty)
            && session.attachmentsLoading == 0 && claude.state == .idle
    }

    private var placeholder: String {
        if !session.claudeAttachments.isEmpty { return "Say what to do with \(session.claudeAttachments.count == 1 ? "it" : "them")…" }
        return claude.items.isEmpty ? "Ask \(claude.engine.title)…" : "Reply to \(claude.engine.title)…"
    }

    private func send() {
        guard canSend else { return }
        let mentioned = ComposerToken.mentions(in: draft, files: Set(session.workspace?.files ?? []))
        let instructions = mentioned.isEmpty ? nil : "The user pointed at these project files with @; read them before answering: " + mentioned.joined(separator: ", ")
        session.askClaude(draft, instructions: instructions, in: claude)
        draft = ""
    }

    // MARK: @ and / lists

    private var openToken: ComposerToken? {
        guard focused, dismissed != draft, let token = ComposerToken.current(in: draft) else { return nil }
        return token
    }

    private func suggestions(for token: ComposerToken) -> [SuggestionList.Row] {
        switch token.kind {
        case .mention:
            guard let workspace = session.workspace else { return [] }
            let open = workspace.documents.compactMap { document -> String? in
                let path = document.url.path
                let root = workspace.url.path + "/"
                return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
            }
            let paths = token.query.isEmpty
                ? Array(open.prefix(8))
                : FuzzyMatch.rank(token.query, in: workspace.files, limit: 8).map(\.path)
            return paths.map { SuggestionList.Row(id: $0, symbol: "doc", title: ($0 as NSString).lastPathComponent, detail: ($0 as NSString).deletingLastPathComponent) }
        case .command:
            return ComposerCommand.matching(token.query, skills: skills).prefix(8).map { command in
                let symbol = if case .skill = command.action { "book.closed" } else { "slash.circle" }
                return SuggestionList.Row(id: command.name, symbol: symbol, title: "/" + command.name, detail: command.detail)
            }
        }
    }

    private func choose(_ index: Int, for token: ComposerToken) {
        let rows = suggestions(for: token)
        guard rows.indices.contains(index) else { return }
        switch token.kind {
        case .mention:
            draft = token.replacing(in: draft, with: "@" + rows[index].id)
        case .command:
            guard let command = ComposerCommand.matching(token.query, skills: skills).first(where: { $0.name == rows[index].id }) else { return }
            draft = ""
            switch command.action {
            case .compact: claude.compact()
            case .newConversation: claude.reset()
            case .context: session.claudeShowsUsage = true
            case .history: session.claudeShowsHistory = true
            case .skills: session.area = .claude
            case .skill(let name): draft = "Use the \(name) skill to "
            }
        }
        picked = 0
    }
}

/// Files for `@` or commands for `/`, over the message box.
private struct SuggestionList: View {
    @Environment(\.theme) private var theme
    struct Row: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var detail: String
    }
    let rows: [Row]
    let picked: Int
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { choose(index) } label: {
                    HStack(spacing: 7) {
                        Image.symbol(row.symbol, side: 11).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).frame(width: 14)
                        Text(row.title).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                        Text(row.detail).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(index == picked ? theme.accentTint.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("↑↓ to move · ↩ or ⇥ to pick · esc to close").font(.dante(size: 10)).foregroundStyle(theme.text3.color).padding(.horizontal, 8).padding(.top, 3)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line2.color))
    }
}

/// A file waiting to go to Claude, with what Claude will see of it.
struct AttachmentChip: View {
    @Environment(\.theme) private var theme
    let attachment: Attachment
    let remove: () -> Void

    static func symbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) { return "photo" }
        if ext == "pdf" { return "doc.richtext" }
        if Attachment.convertibleExtensions.contains(ext) { return "doc.text" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 5) {
            if case .image(_, let base64) = attachment.kind, let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: Self.symbol(for: attachment.name)).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
            }
            Text(attachment.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
            Text(attachment.summary).foregroundStyle(attachment.kind == .reference ? theme.amber.color : theme.text3.color)
            Button(action: remove) {
                Image(systemName: "xmark").font(.dante(size: 8, weight: .bold)).foregroundStyle(theme.text3.color)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .font(.dante(size: 11))
        .foregroundStyle(theme.text.color)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.raised.color))
        .overlay(Capsule().strokeBorder(theme.line2.color))
        .help(help)
    }

    private var help: String {
        let what = switch attachment.kind {
        case .image: "Claude sees this image."
        case .pdf: "Claude reads this PDF, pages and all."
        case .text: "Claude reads this as text."
        case .reference: "Dante can’t convert this file, so Claude gets its path and can open it with its own tools."
        }
        return [what, attachment.note.map { "Dante \($0)." }].compactMap { $0 }.joined(separator: " ")
    }
}

/// Drop files or images anywhere on the Claude panel to attach them.
struct AcceptsAttachments: ViewModifier {
    @Environment(\.theme) private var theme
    let session: Session
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.accent.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(theme.accentTint.opacity(0.5).color)
                        .overlay {
                            Label("Drop to attach for Claude", systemImage: "paperclip")
                                .font(.dante(size: 13, weight: .semibold))
                                .foregroundStyle(theme.accent.color)
                        }
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                for provider in providers {
                    if provider.canLoadObject(ofClass: URL.self) {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url, url.isFileURL else { return }
                            Task { @MainActor in await session.attach([url]) }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                            guard let data else { return }
                            Task { @MainActor in session.attachImage(data) }
                        }
                    }
                }
                return true
            }
    }
}

/// Catches ⌘V while the composer has focus, so files and images on the pasteboard attach
/// instead of pasting as text. `handle` returns false to let the paste through.
private struct PasteInterceptor: NSViewRepresentable {
    let isActive: Bool
    let handle: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard coordinator.isActive,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            return MainActor.assumeIsolated { coordinator.handle?() == true } ? nil : event
        }
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    @MainActor
    final class Coordinator {
        var isActive = false
        var handle: (@MainActor () -> Bool)?
        var monitor: Any?
    }
}
