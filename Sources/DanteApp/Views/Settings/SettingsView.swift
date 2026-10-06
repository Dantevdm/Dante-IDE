import DanteKit
import SwiftUI

/// The Settings window (⌘,). Changes apply straight away; Claude's take effect from the next message.
struct SettingsView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Bindable var preferences = Preferences.shared

    enum Tab: String { case appearance, editor, files, claude }
    @AppStorage("settingsTab") private var tab: Tab = .appearance

    var body: some View {
        TabView(selection: $tab) {
            AppearanceSettings(themeStore: themeStore)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(Tab.appearance)
            EditorSettings(preferences: preferences)
                .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(Tab.editor)
            FileSettings(preferences: preferences)
                .tabItem { Label("Files", systemImage: "doc") }
                .tag(Tab.files)
            ClaudeSettings(preferences: preferences)
                .tabItem { Label("Claude", systemImage: "sparkle") }
                .tag(Tab.claude)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(themeStore.theme.accent.color)
        .preferredColorScheme(themeStore.theme.colorScheme)
    }
}

private struct AppearanceSettings: View {
    @Bindable var themeStore: ThemeStore
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            Picker("Theme", selection: $themeStore.id) {
                ForEach(ThemeID.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Editor font size") {
                Stepper(value: $themeStore.editorFontSize, in: 9...28, step: 1) {
                    Text("\(Int(themeStore.editorFontSize)) pt").monospacedDigit()
                }
            }
            Toggle("Geist and Geist Mono", isOn: $preferences.usesGeist)
                .help("The design’s fonts, bundled with Dante. Off uses the system fonts (SF Pro and SF Mono).")
        }
    }
}

private struct EditorSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Indent width", selection: $preferences.indentWidth) {
                    Text("By language").tag(0)
                    ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                }
                Toggle("Wrap long lines", isOn: $preferences.wrapsLines)
                Toggle("Show completions while typing", isOn: $preferences.completesWhileTyping)
            } footer: {
                Text("“By language” uses 4 spaces for Swift, Python, Rust, Java, Kotlin, C# and PHP, and 2 elsewhere. ⌃Space shows completions at any time.")
            }
            Section("When saving") {
                Toggle("Format with the language server", isOn: $preferences.formatsOnSave)
                Toggle("Trim trailing whitespace", isOn: $preferences.trimsTrailingWhitespace)
                Toggle("End the file with a newline", isOn: $preferences.insertsFinalNewline)
            }
        }
    }
}

private struct FileSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Auto-save", selection: $preferences.autoSave) {
                    ForEach(Preferences.AutoSave.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Auto-save writes files as they are; formatting and whitespace tidying happen only when you save with ⌘S.")
            }
        }
    }
}

private struct ClaudeSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $preferences.claudeModel) {
                    ForEach(Preferences.ClaudeModel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Ask clarifying questions before ambiguous work", isOn: $preferences.claudeAsksFirst)
            } footer: {
                Text("Changes apply from your next message. Claude Code’s own settings, such as sign-in, stay in Claude Code.")
            }
        }
    }
}
