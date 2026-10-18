import DanteKit
import SwiftUI

struct EditorSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Indent width", selection: $preferences.indentWidth) {
                    Text("By language").tag(0)
                    ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                }
                .help("4 spaces for Swift, Python, Rust, Java, Kotlin, C# and PHP; 2 elsewhere.")
                Toggle("Wrap long lines", isOn: $preferences.wrapsLines)
                Toggle("Show completions while typing", isOn: $preferences.completesWhileTyping)
            }
            Section("When saving") {
                Toggle("Format with the language server", isOn: $preferences.formatsOnSave)
                Toggle("Trim trailing whitespace", isOn: $preferences.trimsTrailingWhitespace)
                Toggle("End the file with a newline", isOn: $preferences.insertsFinalNewline)
            }
        }
    }
}

struct FileSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Auto-save", selection: $preferences.autoSave) {
                    ForEach(Preferences.AutoSave.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .help("Auto-save writes files as they are; formatting and tidying happen when you save with ⌘S.")
            }
        }
    }
}
