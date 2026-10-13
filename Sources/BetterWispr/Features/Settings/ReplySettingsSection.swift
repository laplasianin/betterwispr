import BetterWisprCore
import SwiftUI

/// Settings → Reply: the second shortcut that writes a reply from the screen with Claude.
struct ReplySettingsSection: View {
    let model: AppModel
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var keyStatus: String?
    @State private var checking = false

    var body: some View {
        SettingsSection("Reply with Claude") {
            ShortcutRecorder(model: model, title: "Reply shortcut", shortcut: model.settings.reply.shortcut,
                             defaultShortcut: .optionShiftSpace,
                             idleCaption: "Hold it, say what to reply, release. The draft appears in a popup.") { model.changeReplyShortcut($0) }
            RowDivider()
            SettingRow("Claude API key", caption: keyStatus ?? (hasSavedKey ? "Saved in your Keychain." : "From console.anthropic.com. Stored only in your Keychain.")) {
                HStack(spacing: 6) {
                    SecureField(hasSavedKey ? "New key (blank keeps saved key)" : "sk-ant-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    // Buttons keep their natural width; the title column yields instead of the labels turning into "…".
                    Button("Save") { save() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(checking ? "Checking…" : "Test") { test() }.disabled(checking || (!hasSavedKey && key.isEmpty))
                    if hasSavedKey { Button("Remove") { remove() }.foregroundStyle(.red) }
                }
                .fixedSize()
                .layoutPriority(1)
            }
            RowDivider()
            SettingRow("Model", caption: model.settings.reply.model.detail) {
                Picker("Model", selection: setting(\.model)) {
                    ForEach(ClaudeModel.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden()
            }
            RowDivider()
            SettingRow("Effort", caption: "How long Claude thinks. Low keeps short replies fast.") {
                Picker("Effort", selection: setting(\.effort)) {
                    ForEach(ReplyEffort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
            }
            RowDivider()
            SettingRow("Send a screenshot", caption: "Lets Claude see who said what. Off sends only the window's text.") {
                Toggle("Send a screenshot", isOn: setting(\.sendScreenshot)).labelsHidden()
            }
            RowDivider()
            SettingRow("Your name", caption: "Helps Claude tell which messages are yours in group chats and email.") {
                TextField("Name", text: setting(\.userName)).textFieldStyle(.roundedBorder).frame(width: 220)
            }
        } footer: {
            Text("When you use the reply shortcut, the spoken instruction, the focused window's text\(model.settings.reply.sendScreenshot ? " and a screenshot of it" : "") go to Anthropic with your key. Nothing is sent at any other time. Pasting is up to you; BetterWispr never presses Send.")
        }
        .onAppear(perform: load)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<ReplySettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings.reply[keyPath: keyPath] },
                set: { model.settings.reply[keyPath: keyPath] = $0; model.saveSettings() })
    }

    private func load() {
        hasSavedKey = (try? ClaudeClient.keyStore.read(for: ClaudeClient.keyConnection)).flatMap { $0 } != nil
        if model.settings.reply.userName.isEmpty {
            model.settings.reply.userName = NSFullUserName()
            model.saveSettings()
        }
    }

    private func save() {
        do {
            let normalized = try ClaudeClient.normalizedKey(key)
            try ClaudeClient.keyStore.save(normalized, for: ClaudeClient.keyConnection)
            key = ""
            hasSavedKey = true
            keyStatus = "Key saved. Click Test to check it."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try ClaudeClient.keyStore.save("", for: ClaudeClient.keyConnection)
            hasSavedKey = false
            keyStatus = "Key removed. Reply mode is off until you add one."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func test() {
        checking = true
        keyStatus = nil
        let candidate = key
        let selected = model.settings.reply.model
        Task {
            defer { checking = false }
            do {
                let stored = try ClaudeClient.keyStore.read(for: ClaudeClient.keyConnection) ?? ""
                try await ClaudeClient().verify(key: candidate.isEmpty ? stored : candidate, model: selected)
                keyStatus = "Claude answered. \(selected.name) is ready."
            } catch {
                keyStatus = error.localizedDescription
            }
        }
    }
}
