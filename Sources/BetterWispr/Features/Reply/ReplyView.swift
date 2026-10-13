import BetterWisprCore
import SwiftUI

struct ReplyView: View {
    @Bindable var reply: ReplyController
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            footer
        }
        .padding(16)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .onAppear { editing = true }
        .onChange(of: reply.state) { _, state in if state == .preview { editing = true } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill").foregroundStyle(.secondary)
                Text("Reply in \(reply.appName)").font(.headline)
                if let title = reply.windowTitle, !title.isEmpty {
                    Text("· \(title)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if reply.isRecordingEdit {
                    Label("Listening for your edit…", systemImage: "mic.fill").font(.caption).foregroundStyle(.red)
                }
            }
            if reply.needsScreenRecording {
                HStack(spacing: 6) {
                    Text("Allow Screen Recording so Claude can see who said what.").font(.caption).foregroundStyle(.secondary)
                    Button("Allow…") { reply.requestScreenRecording() }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch reply.state {
        case .generating where reply.draft.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing with \(reply.modelName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 8) {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                HStack {
                    if error == .missingKey || error == .invalidKey {
                        Button("Open Settings") { reply.openSettings() }
                    } else {
                        Button("Retry") { reply.retry() }
                    }
                    if reply.hasDraft { Button("Back to draft") { reply.showLastDraft() } }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        case .generating, .preview, .idle:
            // While streaming, the text grows in place and becomes editable once the reply is complete.
            TextEditor(text: $reply.draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 96, maxHeight: 260)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .focused($editing)
                .disabled(reply.state == .generating)
                .opacity(reply.state == .generating ? 0.85 : 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if reply.state == .generating {
                // Stays up after the first words arrive, so a pause in the stream does not look like the end.
                ProgressView().controlSize(.small)
                Text("Writing with \(reply.modelName)…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { reply.regenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .help("Regenerate (⌘R)")
                Button { reply.editByVoice() } label: { Label("Edit by voice", systemImage: "mic") }
                    .help("Say a change to apply (⌘E), or hold the reply shortcut")
            }
            Spacer()
            Text(reply.state == .generating ? "Esc to stop" : "Esc to close").font(.caption).foregroundStyle(.tertiary)
            Button("Paste") { reply.paste() }
                .buttonStyle(.borderedProminent)
                .help("Paste into \(reply.appName) (Return)")
                .disabled(reply.state != .preview || reply.isRecordingEdit)
        }
        .disabled(reply.isRecordingEdit)
    }
}
