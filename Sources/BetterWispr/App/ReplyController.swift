import AppKit
import BetterWisprCore
import Observation

/// One reply session: captures the screen while the user speaks, asks Claude for a draft and owns the popup's state.
/// Recording and recognition run through `AppModel`, so the recorder and the capsule are never shared between two state machines.
@MainActor @Observable
final class ReplyController {
    enum State: Equatable {
        case idle, generating, preview
        case failed(ReplyError)
    }

    private(set) var state: State = .idle { didSet { onChange?() } }
    /// The text in the popup; the user may edit it before pasting.
    var draft = ""
    private(set) var appName = ""
    private(set) var windowTitle: String?
    /// A spoken edit is being recorded or recognized while the popup stays open.
    private(set) var isRecordingEdit = false { didSet { onChange?() } }
    /// Screenshots are on but macOS has not granted Screen Recording; the popup offers to ask.
    private(set) var needsScreenRecording = false
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let client = ClaudeClient()
    @ObservationIgnored private var request: ReplyRequest?
    @ObservationIgnored private var lastModelDraft = ""
    @ObservationIgnored private var target: NSRunningApplication?
    @ObservationIgnored private var context: Task<DictationContext, Never>?
    @ObservationIgnored private var screenshot: Task<Data?, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    var modelName: String { model.settings.reply.model.name }
    var hasDraft: Bool { request?.previousDrafts.isEmpty == false }

    // MARK: Recording hooks called by AppModel

    /// Starts reading the window while the microphone starts; a spoken edit keeps the context from the first draft.
    func beginCapture(target: NSRunningApplication?) {
        if state == .idle {
            self.target = target
            context?.cancel()
            screenshot?.cancel()
            let settings = model.settings
            context = target.map { DictationContext.capture(from: $0, recognizingScreen: !settings.reply.sendScreenshot && settings.recognizeScreenText) }
            screenshot = settings.reply.sendScreenshot ? target.map { WindowSnapshot.capture(from: $0) } : nil
            needsScreenRecording = settings.reply.sendScreenshot && !CGPreflightScreenCaptureAccess()
            appName = target?.localizedName ?? "your app"
        } else {
            isRecordingEdit = true
        }
    }

    func recordingFinished(_ recording: DictationRecording) {
        let token = model.generation
        model.statusMessage = "Reply: transcribing…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let (_, cleaned) = try await model.recognize(recording, token: token)
                let spoken = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else {
                    isRecordingEdit = false
                    model.finishReply(.noSpeech)
                    return
                }
                if state == .idle {
                    model.statusMessage = "Writing reply with \(modelName)…"
                    await compose(spoken, recording: recording)
                    model.finishReply(nil)
                } else {
                    model.finishReply(nil)
                    isRecordingEdit = false
                    await applyEdit(spoken)
                }
            } catch {
                isRecordingEdit = false
                guard model.generation == token else { return }
                model.finishReply(DictationFailure(title: "Couldn’t transcribe.", message: error.localizedDescription))
            }
        }
    }

    /// Called when the capsule session is cancelled or discarded while this controller still waits on it.
    func cancelPending() {
        work?.cancel()
        work = nil
        isRecordingEdit = false
        if !hasDraft { reset() }
    }

    // MARK: Generation

    private func compose(_ instruction: String, recording: DictationRecording) async {
        let context = await self.context?.value(within: .seconds(2))
        let screenshot = await self.screenshot?.value(within: .seconds(3)) ?? nil
        windowTitle = context?.window.flatMap { $0.split(separator: "\n").first.map(String.init) }?.replacingOccurrences(of: "Active Window: ", with: "")
        request = ReplyRequest(instruction: instruction, windowText: context?.window, selectedText: context?.selectedText,
                               windowTitle: windowTitle, screenshot: screenshot,
                               userName: model.settings.reply.userName, appName: recording.target?.localizedName ?? appName)
        await generate()
    }

    private func applyEdit(_ edit: String) async {
        guard request != nil else { return }
        request?.edits.append(edit)
        request?.draft = draft
        request?.action = .applyEdits
        await generate()
    }

    private func generate() async {
        guard let pending = request else { return }
        state = .generating
        do {
            let key = try ClaudeClient.keyStore.read(for: ClaudeClient.keyConnection) ?? ""
            let settings = model.settings.reply
            let text = try await client.reply(to: pending, model: settings.model, effort: settings.effort, key: key)
            request?.previousDrafts.append(text)
            draft = text
            lastModelDraft = text
            state = .preview
        } catch let error as ReplyError {
            state = .failed(error)
        } catch is CancellationError {
            state = hasDraft ? .preview : .idle
        } catch {
            state = .failed(.network(error.localizedDescription))
        }
    }

    // MARK: Popup actions

    func regenerate() {
        guard state == .preview || isFailed, request != nil else { return }
        request?.draft = draft
        request?.action = draft == lastModelDraft ? .regenerate : .rework
        work = Task { [weak self] in await self?.generate() }
    }

    func retry() {
        guard isFailed, request != nil else { return }
        work = Task { [weak self] in await self?.generate() }
    }

    /// Records a spoken edit through the capsule; the popup stays open.
    func editByVoice() {
        guard state == .preview || isFailed, !model.isBusy else { return }
        model.startRecording(held: false, reply: true)
    }

    func paste() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .preview, !text.isEmpty else { return }
        let target = target
        let settings = model.settings
        reset()
        Task {
            // Let the panel close and the target's window take keyboard focus back before posting ⌘V.
            try? await Task.sleep(for: .milliseconds(80))
            let integration: any TextOutputIntegration = settings.autoPaste
                ? FocusedAppIntegration(keepsCopy: settings.copyToClipboard) : ClipboardIntegration()
            do {
                let result = try await integration.deliver(text, to: target)
                if result != .pasted(into: target?.localizedName ?? "your app") { ToastWindow.shared.show(Toast(result)) }
            } catch {
                ToastWindow.shared.show(Toast(failure: "Couldn’t paste the reply", error))
            }
        }
    }

    /// Closes the popup. A generation in flight is cancelled; nothing is pasted and the clipboard is untouched.
    func dismiss() {
        work?.cancel()
        work = nil
        if model.replyMode { model.cancelRecording() }
        reset()
    }

    func openSettings() {
        model.selectedPage = .settings
        model.onShowDashboard?()
        NSApplication.shared.activate(ignoringOtherApps: true)
        dismiss()
    }

    /// Shows the macOS Screen Recording prompt; the permission applies from the next reply on.
    func requestScreenRecording() {
        needsScreenRecording = !CGRequestScreenCaptureAccess()
        onChange?()
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    private func reset() {
        context?.cancel()
        screenshot?.cancel()
        context = nil
        screenshot = nil
        request = nil
        draft = ""
        lastModelDraft = ""
        target = nil
        isRecordingEdit = false
        state = .idle
    }
}
