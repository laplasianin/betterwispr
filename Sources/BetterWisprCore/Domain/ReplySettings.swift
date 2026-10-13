import Foundation

/// Claude models that read screenshots; the raw value is the Messages API model ID.
public enum ClaudeModel: String, Codable, CaseIterable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public var name: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        }
    }

    public var detail: String {
        switch self {
        case .opus: "Best replies. About 1–2 cents each."
        case .sonnet: "Faster and cheaper."
        case .haiku: "Fastest and cheapest; may lose track of long threads."
        }
    }
}

/// How long Claude thinks before replying; low keeps short replies fast.
public enum ReplyEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

/// Settings for reply mode: the second shortcut that writes a reply from the screen with Claude.
public struct ReplySettings: Codable, Equatable, Sendable {
    public var shortcut: DictationShortcut = .optionShiftSpace
    public var model: ClaudeModel = .opus
    public var effort: ReplyEffort = .low
    /// Sends a JPEG of the focused window with each request; off sends window text only.
    public var sendScreenshot = true
    /// Tells the model which participant is the user; empty leaves it to the screenshot.
    public var userName = ""

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decodeIfPresent(DictationShortcut.self, forKey: .shortcut) ?? .optionShiftSpace
        model = try container.decodeIfPresent(ClaudeModel.self, forKey: .model) ?? .opus
        effort = try container.decodeIfPresent(ReplyEffort.self, forKey: .effort) ?? .low
        sendScreenshot = try container.decodeIfPresent(Bool.self, forKey: .sendScreenshot) ?? true
        userName = try container.decodeIfPresent(String.self, forKey: .userName) ?? ""
    }
}
