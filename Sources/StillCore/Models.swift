import Foundation

public enum Role: String, Codable, Sendable { case user, assistant, system }
public enum MessageStatus: String, Codable, Sendable { case complete, streaming, stopped, failed }

public struct Message: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var role: Role
    public var text: String
    public var reasoning: String?
    public var date: Date
    public var status: MessageStatus
    public var model: String?
    public var note: String?
    public init(role: Role, text: String, status: MessageStatus = .complete, model: String? = nil, reasoning: String? = nil) {
        id = UUID(); self.role = role; self.text = text; date = Date(); self.status = status; self.model = model; self.reasoning = reasoning
    }
}

public struct Conversation: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var title: String = "New chat"
    public var messages: [Message] = []
    public var localModel: LocalModel?
    public var draft: String = ""
    public var updatedAt: Date = Date()
    public init() {}
    public var preview: String { messages.last(where: { !$0.text.isEmpty })?.text.replacingOccurrences(of: "\n", with: " ") ?? "No messages yet" }
}

public enum BackendMode: String, Codable, Sendable, CaseIterable { case inkling, gemma, compatible }

public struct BackendSettings: Codable, Sendable, Equatable {
    public var mode: BackendMode = .inkling
    public var baseURL: String = "http://127.0.0.1:1234/v1"
    public var model: String = ""
    public var displayName: String = "My model"
    public var systemPrompt: String = "You are a thoughtful, helpful conversation partner. Be clear and concise unless asked for detail."
    public init() {}
    public var localModel: LocalModel? {
        switch mode { case .inkling: .inklingMini; case .gemma: .gemma12B; case .compatible: nil }
    }
    public var label: String { localModel?.title ?? (displayName.isEmpty ? model : displayName) }
    public func validatedEndpoint() throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ChatError.message("Enter a server address such as http://127.0.0.1:1234/v1.")
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard url.scheme == "https" || local else { throw ChatError.message("Use HTTPS for a server outside this Mac.") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.message("Enter the model ID used by your server.") }
        return url
    }
}

public struct SavedState: Codable, Sendable {
    public var version = 1
    public var conversations: [Conversation] = []
    public var selectedID: UUID?
    public var settings = BackendSettings()
    public init() {}
    public mutating func recoverInterruptedReplies() {
        for c in conversations.indices {
            for m in conversations[c].messages.indices where conversations[c].messages[m].status == .streaming {
                conversations[c].messages[m].status = .stopped
                conversations[c].messages[m].note = "Interrupted when the app closed."
            }
        }
    }
}

public enum ChatError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

public struct RequestMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public let reasoningContent: String?
    enum CodingKeys: String, CodingKey { case role, content; case reasoningContent = "reasoning_content" }
    public init(role: String, content: String, reasoningContent: String? = nil) {
        self.role = role; self.content = content
        self.reasoningContent = role == "assistant" ? reasoningContent : nil
    }
    public init(message: Message) {
        self.init(role: message.role.rawValue, content: message.text, reasoningContent: message.reasoning)
    }
}

public struct CompletionUpdate: Sendable {
    public var text: String
    public var reasoning: String
    public var isThinking: Bool
    public var finishReason: String?
    public var generatedTokens: Int?
    public init(text: String = "", reasoning: String = "", isThinking: Bool = false, finishReason: String? = nil, generatedTokens: Int? = nil) {
        self.text = text; self.reasoning = reasoning; self.isThinking = isThinking; self.finishReason = finishReason; self.generatedTokens = generatedTokens
    }
}
