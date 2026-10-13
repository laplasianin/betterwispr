import Foundation

public enum ReplyError: LocalizedError, Equatable, Sendable {
    case missingKey
    case invalidKey
    case emptyInstruction
    case rateLimited
    case server(Int)
    case badRequest(String)
    case network(String)
    case timedOut
    case refused
    case truncated
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Claude API key in Settings → Reply."
        case .invalidKey: "Claude rejected the API key. Check it in Settings → Reply."
        case .emptyInstruction: "No instruction heard. Hold the shortcut and say what to reply."
        case .rateLimited: "Claude is busy right now. Try again in a moment."
        case .server(let status): "Claude returned HTTP \(status). Try again in a moment."
        case .badRequest(let message): "Claude rejected the request: \(message)"
        case .network(let message): "Couldn't reach Claude. \(message)"
        case .timedOut: "Claude took too long to answer."
        case .refused: "Claude declined to write this reply. Try rephrasing with a spoken edit."
        case .truncated: "The reply was cut off. Try again."
        case .emptyReply: "Claude returned an empty or unreadable reply. Try again."
        }
    }

    /// Whether the same request is worth sending once more without the user changing anything.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .network, .timedOut: true
        default: false
        }
    }
}
