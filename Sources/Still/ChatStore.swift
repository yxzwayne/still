import AppKit
import Foundation
import Observation
import StillCore

@Observable final class LiveReply {
    let conversationID: UUID
    let timing: ReplyTiming
    var message: Message
    var phase = "Connecting…"

    init(conversationID: UUID, message: Message, started: ContinuousClock.Instant) {
        self.conversationID = conversationID
        self.message = message
        timing = ReplyTiming(id: message.id, started: started)
    }
}

@Observable final class ChatStore {
    private(set) var state = SavedState()
    private(set) var isRestored = false
    private(set) var draft = ""
    private(set) var focusID: UUID? = UUID()
    private(set) var activeReply: LiveReply?
    private(set) var lastReplyTiming: ReplyTiming?
    var search = ""
    var error: String?
    let runtime = ManagedRuntime()
    let storage: ChatStorage
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var writable = true
    private let persistenceQueue = DispatchQueue(label: "app.still.chat-storage", qos: .utility)

    var busy: Bool { activeReply != nil }
    var replyingHere: Bool { activeReply != nil && activeReply?.conversationID == state.selectedID }
    var selected: Conversation? { state.conversations.first { $0.id == state.selectedID } }
    var chats: [Conversation] {
        state.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) } }.sorted { $0.updatedAt > $1.updatedAt }
    }

    init() {
        let custom = ProcessInfo.processInfo.environment["STILL_DATA_DIR"]
        let directory = custom.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Still")
        storage = ChatStorage(directory: directory)
    }

    func restore() async {
        guard !isRestored else { return }
        let storage = self.storage
        let result = await Task.detached(priority: .userInitiated) { Result { try storage.load() } }.value
        guard !isRestored else { return }
        finishRestore(result)
    }

    private func finishRestore(_ result: Result<SavedState, any Error>) {
        let earlyDraft = draft
        do {
            state = try result.get()
        } catch {
            writable = false
            self.error = "Your saved chats could not be opened. \(error.localizedDescription)"
        }

        if state.conversations.isEmpty {
            var chat = Conversation()
            chat.localModel = state.settings.localModel
            state.conversations.append(chat)
        }
        if selected == nil { state.selectedID = state.conversations.first?.id }
        if let model = selected?.localModel { state.settings.mode = model.mode }
        draft = [selected?.draft ?? "", earlyDraft].filter { !$0.isEmpty }.joined(separator: "\n")
        isRestored = true
        if !earlyDraft.isEmpty { saveSoon() }
    }

    func focusComposer() { focusID = UUID() }

    func updateDraft(_ text: String) {
        guard draft != text else { return }
        draft = text
        saveSoon()
    }

    func select(_ id: UUID?, focusComposer: Bool = true) {
        guard isRestored, let id, id != state.selectedID, state.conversations.contains(where: { $0.id == id }) else { return }
        switchConversation(to: id, focusComposer: focusComposer)
        if !busy, let model = selected?.localModel { selectModel(model) }
        saveSoon()
    }

    func selectModel(_ model: LocalModel) {
        guard isRestored, !busy else { return }
        if state.settings.localModel != model { runtime.unload() }
        state.settings.mode = model.mode
        updateSelected { $0.localModel = model }
        saveNow()
    }

    func newChat() {
        guard isRestored else { return }
        updateSelected { $0.draft = draft }
        if let empty = state.conversations.first(where: { $0.messages.isEmpty && $0.draft.isEmpty }) {
            switchConversation(to: empty.id)
        } else {
            var chat = Conversation()
            chat.localModel = state.settings.localModel
            state.conversations.insert(chat, at: 0)
            switchConversation(to: chat.id)
        }
        let currentModel = state.settings.localModel
        updateSelected { $0.localModel = currentModel }
        search = ""
        focusID = UUID()
        saveSoon()
    }

    func rename(_ id: UUID, to title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = state.conversations.firstIndex(where: { $0.id == id }) else { return }
        state.conversations[index].title = value
        saveNow()
    }

    func delete(_ id: UUID) {
        if activeReply?.conversationID == id { stop() }
        state.conversations.removeAll { $0.id == id }
        if state.selectedID == id {
            switchConversation(to: state.conversations.first?.id)
            if !busy, let model = selected?.localModel { selectModel(model) }
        }
        if state.conversations.isEmpty { newChat() }
        saveNow()
    }

    var canSend: Bool {
        isRestored && !busy && state.selectedID != nil && draft.contains { !$0.isWhitespace }
    }

    func send() {
        let started = ContinuousClock.now
        guard canSend, let id = state.selectedID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.utf8.count > 48000 { error = "That message is too large. Try a shorter excerpt."; return }
        updateSelected { chat in
            if chat.messages.isEmpty { chat.title = String(text.replacingOccurrences(of: "\n", with: " ").prefix(52)) }
            chat.messages.append(Message(role: .user, text: text))
            chat.draft = ""
            chat.updatedAt = Date()
        }
        draft = ""
        generate(in: id, started: started)
    }

    func retry() {
        let started = ContinuousClock.now
        guard isRestored, !busy, let id = state.selectedID, selected?.messages.last?.role == .assistant else { return }
        updateSelected { $0.messages.removeLast() }
        generate(in: id, started: started)
    }

    private func generate(in chatID: UUID, started: ContinuousClock.Instant) {
        guard let index = state.conversations.firstIndex(where: { $0.id == chatID }) else { return }
        let settings = state.settings
        let history = state.conversations[index].messages
        let message = Message(role: .assistant, text: "", status: .streaming, model: settings.label)
        let reply = LiveReply(conversationID: chatID, message: message, started: started)
        let timing = reply.timing
        state.conversations[index].messages.append(message)
        activeReply = reply
        lastReplyTiming = timing
        error = nil
        saveNow()

        generation = Task { [weak self, reply] in
            guard let self else { return }
            do {
                let interval = Duration.milliseconds(32)
                let firstText: @Sendable () -> Void = { timing.receivedText() }
                let backend: OpenAICompatibleBackend
                if let local = settings.localModel {
                    reply.phase = "Starting \(local.title)…"
                    try await runtime.ready(local)
                    backend = OpenAICompatibleBackend(baseURL: ManagedRuntime.endpoint, model: local.modelPath.path, updateInterval: interval, onFirstText: firstText)
                } else {
                    let endpoint = try settings.validatedEndpoint()
                    backend = OpenAICompatibleBackend(baseURL: endpoint, model: settings.model, apiKey: Keychain.read(account: endpoint.absoluteString), updateInterval: interval, onFirstText: firstText)
                }
                try Task.checkCancellation()
                reply.phase = "Waiting for a reply…"
                let messages = [RequestMessage(role: "system", content: settings.systemPrompt)]
                    + history.filter { !$0.text.isEmpty || !($0.reasoning ?? "").isEmpty }.map(RequestMessage.init(message:))
                try await backend.reply(to: messages) { [weak self] update in
                    await self?.receive(update, in: reply)
                }
                guard activeReply === reply else { return }
                reply.message.status = .complete
            } catch {
                guard activeReply === reply else { return }
                let cancelled = Task.isCancelled || error is CancellationError
                reply.message.status = cancelled ? .stopped : .failed
                reply.message.note = cancelled ? "Stopped" : error.localizedDescription
            }
            finish(reply)
            runtime.scheduleUnload()
            if let model = selected?.localModel, model != state.settings.localModel { selectModel(model) }
            else { saveNow() }
        }
    }

    private func receive(_ update: CompletionUpdate, in reply: LiveReply) {
        guard activeReply === reply else { return }
        let phase = !update.text.isEmpty ? "Replying…" : update.reasoning.isEmpty ? reply.phase : "Reasoning…"
        if reply.phase != phase { reply.phase = phase }
        var message = reply.message
        message.text = update.text
        message.reasoning = update.reasoning.isEmpty ? nil : update.reasoning
        if update.finishReason == "length" { message.note = "Reply reached the output limit." }
        if message != reply.message { reply.message = message }
        saveSoon()
    }

    func stop() {
        guard let reply = activeReply else { return }
        generation?.cancel()
        reply.message.status = .stopped
        reply.message.note = "Stopped"
        finish(reply)
        runtime.unload()
        if let model = selected?.localModel { state.settings.mode = model.mode }
        saveNow()
    }

    private func finish(_ reply: LiveReply) {
        if let index = state.conversations.firstIndex(where: { $0.id == reply.conversationID }),
           state.conversations[index].messages.last?.id == reply.message.id {
            state.conversations[index].messages[state.conversations[index].messages.count - 1] = reply.message
        }
        activeReply = nil
        generation = nil
    }

    func saveSettings(_ settings: BackendSettings, apiKey: String) throws {
        guard isRestored else { throw ChatError.message("Wait for your chats to open before saving settings.") }
        guard !busy else { throw ChatError.message("Stop the current reply before changing the backend.") }
        if settings.mode == .compatible {
            let endpoint = try settings.validatedEndpoint()
            try Keychain.write(apiKey, account: endpoint.absoluteString)
        }
        runtime.unload()
        state.settings = settings
        updateSelected { $0.localModel = settings.localModel }
        saveNow()
    }

    func shutdown() {
        if !isRestored, !draft.isEmpty { finishRestore(Result { try storage.load() }) }
        stop()
        runtime.unload()
        saveTask?.cancel()
        guard isRestored, writable else { return }
        let state = snapshot()
        let storage = self.storage
        // Flush the final snapshot after any queued writes before the process exits.
        persistenceQueue.sync { try? storage.save(state) }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isRestored, writable else { return }
        let state = snapshot()
        let storage = self.storage
        persistenceQueue.async { [weak self] in
            do {
                try storage.save(state)
            } catch {
                let message = "Could not save your chats: \(error.localizedDescription)"
                Task { @MainActor [weak self] in self?.error = message }
            }
        }
    }

    private func saveSoon() {
        guard isRestored, writable, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                self?.saveNow()
            } catch {}
        }
    }

    private func snapshot() -> SavedState {
        var snapshot = state
        if let index = snapshot.conversations.firstIndex(where: { $0.id == snapshot.selectedID }) {
            snapshot.conversations[index].draft = draft
        }
        if let reply = activeReply,
           let index = snapshot.conversations.firstIndex(where: { $0.id == reply.conversationID }),
           snapshot.conversations[index].messages.last?.id == reply.message.id {
            snapshot.conversations[index].messages[snapshot.conversations[index].messages.count - 1] = reply.message
        }
        return snapshot
    }

    private func switchConversation(to id: UUID?, focusComposer: Bool = true) {
        guard id != state.selectedID else { return }
        updateSelected { $0.draft = draft }
        state.selectedID = id
        draft = selected?.draft ?? ""
        focusID = focusComposer ? UUID() : nil
    }

    private func updateSelected(_ change: (inout Conversation) -> Void) {
        guard let index = state.conversations.firstIndex(where: { $0.id == state.selectedID }) else { return }
        change(&state.conversations[index])
    }
}
