import AppKit
import BetterWisprCore
import Observation

@MainActor @Observable
final class ReplyController {
    enum State: Equatable { case idle, generating, preview }

    private(set) var state: State = .idle
    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    func beginCapture(target: NSRunningApplication?) {}
    func recordingFinished(_ recording: DictationRecording) { model.finishReply(nil) }
    func cancelPending() {}
}
