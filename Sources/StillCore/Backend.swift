import Foundation

public protocol ChatBackend: Sendable {
    func reply(to messages: [RequestMessage], onUpdate: @escaping @Sendable (CompletionUpdate) async -> Void) async throws
}

public struct OpenAICompatibleBackend: ChatBackend {
    public let baseURL: URL
    public let model: String
    public let apiKey: String
    private let updateInterval: Duration?
    private let onFirstText: (@Sendable () -> Void)?

    public init(baseURL: URL, model: String, apiKey: String = "", updateInterval: Duration? = nil, onFirstText: (@Sendable () -> Void)? = nil) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey
        self.updateInterval = updateInterval
        self.onFirstText = onFirstText
    }

    @concurrent public func reply(to messages: [RequestMessage], onUpdate: @escaping @Sendable (CompletionUpdate) async -> Void) async throws {
        guard let updateInterval else {
            try await stream(to: messages, onUpdate: onUpdate)
            return
        }
        let (updates, output) = AsyncStream.makeStream(of: CompletionUpdate.self, bufferingPolicy: .bufferingNewest(1))
        let batcher = CompletionBatcher(interval: updateInterval, output: output)
        async let delivery: Void = Self.deliver(updates, to: onUpdate)
        do {
            try await stream(to: messages) { await batcher.append($0) }
        } catch {
            await batcher.finish()
            await delivery
            throw error
        }
        await batcher.finish()
        await delivery
    }

    private static func deliver(_ updates: AsyncStream<CompletionUpdate>, to onUpdate: @Sendable (CompletionUpdate) async -> Void) async {
        for await update in updates { await onUpdate(update) }
    }

    private func stream(to messages: [RequestMessage], onUpdate: @escaping @Sendable (CompletionUpdate) async -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let messageData = try JSONEncoder().encode(messages)
        let payload: [String: Any] = [
            "model": model,
            "messages": try JSONSerialization.jsonObject(with: messageData),
            "stream": true,
            "max_completion_tokens": 2048
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1200
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatError.message("The server returned an unreadable response.") }
        guard (200...299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count >= 8192 { break } }
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let detail = (json?["error"] as? String) ?? (json?["error"] as? [String: Any])?["message"] as? String
            throw ChatError.message(detail ?? "The server returned an error (\(http.statusCode)). Check the model and connection in Settings.")
        }
        var sse = SSEDecoder()
        var answer = ""
        var reasoning = ""
        var finishReason: String?
        var ended = false
        var receivedText = false
        var lineBytes = Data()
        // AsyncBytes.lines can omit empty lines. SSE uses them as frame boundaries.
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte != 10 {
                lineBytes.append(byte)
                guard lineBytes.count < 2_000_000 else { throw ChatError.message("The server sent an oversized stream event.") }
                continue
            }
            if lineBytes.last == 13 { lineBytes.removeLast() }
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            guard let payload = sse.consume(line: line) else { continue }
            if payload == "[DONE]" { ended = true; break }
            guard let data = payload.data(using: .utf8), let chunk = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ChatError.message("The server sent an invalid streaming response.")
            }
            if let error = chunk["error"] { throw ChatError.message((error as? String) ?? (error as? [String: Any])?["message"] as? String ?? "The model could not finish its reply.") }
            let choices = chunk["choices"] as? [[String: Any]] ?? []
            var thinking = false
            for choice in choices {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if let text = delta["content"] as? String { answer += text }
                if let thought = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) {
                    reasoning += thought
                    thinking = thinking || !thought.isEmpty
                }
                if let reason = choice["finish_reason"] as? String { finishReason = reason }
            }
            if !receivedText, answer.contains(where: { !$0.isWhitespace }) {
                receivedText = true
                onFirstText?()
            }
            let count = (chunk["usage"] as? [String: Any])?["completion_tokens"] as? Int
            await onUpdate(CompletionUpdate(text: answer, reasoning: reasoning, isThinking: thinking, finishReason: finishReason, generatedTokens: count))
        }
        try Task.checkCancellation()
        guard ended || finishReason != nil else { throw ChatError.message("The connection ended before the reply finished. You can retry it.") }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.message("The model used its reply budget without producing an answer. Try a shorter question or retry.")
        }
        await onUpdate(CompletionUpdate(text: answer, reasoning: reasoning, finishReason: finishReason))
    }
}

actor CompletionBatcher {
    let interval: Duration
    let output: AsyncStream<CompletionUpdate>.Continuation
    var pending: CompletionUpdate?
    var timer: Task<Void, Never>?
    var hasAnswer = false
    var hasReasoning = false

    init(interval: Duration, output: AsyncStream<CompletionUpdate>.Continuation) {
        self.interval = interval
        self.output = output
    }

    func append(_ update: CompletionUpdate) {
        pending = update
        let firstAnswer = !hasAnswer && update.text.contains(where: { !$0.isWhitespace })
        let firstReasoning = !hasReasoning && !update.reasoning.isEmpty
        if firstAnswer || firstReasoning {
            hasAnswer = hasAnswer || firstAnswer
            hasReasoning = hasReasoning || firstReasoning
            flush()
            return
        }
        guard timer == nil else { return }
        timer = Task { [weak self, interval] in
            try? await Task.sleep(for: interval)
            await self?.flushTimer()
        }
    }

    private func flushTimer() {
        guard !Task.isCancelled else { return }
        flush()
    }

    func finish() {
        flush()
        output.finish()
    }

    private func flush() {
        timer?.cancel()
        timer = nil
        if let pending { output.yield(pending) }
        pending = nil
    }
}
