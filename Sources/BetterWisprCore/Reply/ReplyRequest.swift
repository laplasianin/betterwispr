import Foundation

/// Everything one reply generation sends to Claude: the spoken instruction, what the user sees, and the drafting history.
public struct ReplyRequest: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// First draft from the instruction.
        case compose
        /// A noticeably different variant; `previousDrafts` holds what the model already wrote.
        case regenerate
        /// The user edited `draft` by hand; rework it, keeping the meaning of their changes.
        case rework
        /// Apply the spoken `edits` to `draft`.
        case applyEdits
    }

    public var instruction: String
    public var windowText: String?
    public var selectedText: String?
    public var windowTitle: String?
    /// JPEG bytes, or nil to send text only.
    public var screenshot: Data?
    public var userName: String
    public var appName: String
    /// A writing mode's instructions for the target app or website, when one matches.
    public var styleInstructions: String?
    /// The tone the user set for this app's category or in the matching mode; nil lets the model follow the conversation.
    public var tone: StyleTone?
    public var draft: String?
    public var previousDrafts: [String] = []
    public var edits: [String] = []
    public var action: Action = .compose

    public init(instruction: String, windowText: String?, selectedText: String?, windowTitle: String?,
                screenshot: Data?, userName: String, appName: String) {
        self.instruction = instruction
        self.windowText = windowText
        self.selectedText = selectedText
        self.windowTitle = windowTitle
        self.screenshot = screenshot
        self.userName = userName
        self.appName = appName
    }

    /// The JSON body for `POST /v1/messages`.
    public func body(model: ClaudeModel, effort: ReplyEffort) -> [String: Any] {
        var content: [[String: Any]] = []
        if let screenshot {
            // The system prompt and screenshot repeat unchanged across regenerations and edits; a cache breakpoint
            // after the image lets those requests read both from the prompt cache instead of paying for them again.
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshot.base64EncodedString()],
                            "cache_control": ["type": "ephemeral"]])
        }
        content.append(["type": "text", "text": ReplyPrompt.userText(self)])
        // Thinking tokens count against this cap on these models, so it leaves room for reasoning before the reply.
        return ["model": model.rawValue,
                "max_tokens": 4096,
                "system": ReplyPrompt.system,
                "output_config": ["effort": effort.rawValue],
                "messages": [["role": "user", "content": content]]]
    }
}
