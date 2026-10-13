import Foundation
import Testing
@testable import BetterWisprCore

@Test func replySettingsDefaultAndDecodeFromOlderWorkspaces() throws {
    let legacy = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"apple","showCapsule":true,"silenceThreshold":0.002}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(settings.reply == ReplySettings())
    #expect(settings.reply.shortcut == .optionShiftSpace)
    #expect(settings.reply.shortcut.displayName == "⌥⇧ Space")
    #expect(settings.reply.model == .opus)
    #expect(ClaudeModel.opus.rawValue == "claude-opus-5-5")
    #expect(ClaudeModel.sonnet.rawValue == "claude-sonnet-5-5")
    #expect(ClaudeModel.haiku.rawValue == "claude-haiku-5-5")
    #expect(settings.reply.effort == .low)
    #expect(settings.reply.sendScreenshot)
    #expect(settings.reply.userName == "")

    var changed = settings
    changed.reply.model = .haiku
    changed.reply.sendScreenshot = false
    changed.reply.userName = "Ivan"
    let encoded = try JSONEncoder().encode(changed)
    #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == changed)

    let partial = #"{"model":"claude-sonnet-5-5"}"#
    let decoded = try JSONDecoder().decode(ReplySettings.self, from: Data(partial.utf8))
    #expect(decoded.model == .sonnet)
    #expect(decoded.effort == .low)
    #expect(decoded.shortcut == .optionShiftSpace)
}
