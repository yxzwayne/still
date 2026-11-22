import Foundation
import Testing
@testable import StillCore

@Test func sseHandlesCommentsMultilineAndDone() {
    var decoder = SSEDecoder()
    #expect(decoder.consume(line: ": heartbeat") == nil)
    #expect(decoder.consume(line: "event: message") == nil)
    #expect(decoder.consume(line: "data: {\"choices\":") == nil)
    #expect(decoder.consume(line: "data: []}") == nil)
    #expect(decoder.consume(line: "") == "{\"choices\":\n[]}")
    #expect(decoder.consume(line: "") == nil)
    #expect(decoder.consume(line: "data:[DONE]") == nil)
    #expect(decoder.consume(line: "") == "[DONE]")
}

@Test func persistenceRestoresDraftAndRecoversInterruptedReplies() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = ChatStorage(directory: directory)
    var chat = Conversation(); chat.draft = "An unsent draft"; chat.title = "Saved chat"
    chat.messages = [Message(role: .user, text: "Hello"), Message(role: .assistant, text: "Partial", status: .streaming, reasoning: "Compare both options.")]
    var state = SavedState(); state.conversations = [chat]; state.selectedID = chat.id
    try storage.save(state)
    let loaded = try storage.load()
    #expect(loaded.selectedID == chat.id)
    #expect(loaded.conversations[0].draft == "An unsent draft")
    #expect(loaded.conversations[0].messages.last?.status == .stopped)
    #expect(loaded.conversations[0].messages.last?.text == "Partial")
    #expect(loaded.conversations[0].messages.last?.reasoning == "Compare both options.")
    let replay = RequestMessage(message: loaded.conversations[0].messages.last!)
    #expect(replay.reasoningContent == "Compare both options.")
    #expect(!String(data: try Data(contentsOf: storage.fileURL), encoding: .utf8)!.contains("apiKey"))
}

@Test func corruptStorageIsNotOverwrittenByLoading() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storage = ChatStorage(directory: directory)
    let bad = Data("not json".utf8); try bad.write(to: storage.fileURL)
    #expect(throws: (any Error).self) { try storage.load() }
    #expect(try Data(contentsOf: storage.fileURL) == bad)
}

@Test func endpointValidationProtectsKeysAndAllowsLocalServers() throws {
    var settings = BackendSettings(); settings.mode = .compatible; settings.model = "test"
    settings.baseURL = "http://127.0.0.1:8080/v1"
    #expect(try settings.validatedEndpoint().host == "127.0.0.1")
    settings.baseURL = "https://example.com/v1"
    #expect(try settings.validatedEndpoint().scheme == "https")
    settings.baseURL = "http://example.com/v1"
    #expect(throws: ChatError.self) { try settings.validatedEndpoint() }
    settings.baseURL = "https://secret@example.com/v1"
    #expect(throws: ChatError.self) { try settings.validatedEndpoint() }
}

@Test func oldChatsLoadWithoutReasoning() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = ChatStorage(directory: directory)
    var state = SavedState(); var chat = Conversation()
    chat.messages = [Message(role: .assistant, text: "An older answer")]
    state.conversations = [chat]
    try storage.save(state)
    let bytes = try Data(contentsOf: storage.fileURL)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("reasoning"))
    let restored = try storage.load()
    #expect(restored.conversations[0].messages[0].reasoning == nil)
    #expect(restored.conversations[0].messages[0].text == "An older answer")
}

@Test func reasoningUsesWireFieldAndOnlyAssistantRole() throws {
    let message = RequestMessage(role: "assistant", content: "Answer", reasoningContent: "Reason")
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: String])
    #expect(json["reasoning_content"] == "Reason")
    #expect(json["reasoningContent"] == nil)
    #expect(RequestMessage(role: "user", content: "Question", reasoningContent: "Ignore").reasoningContent == nil)
}

@Test func curatedModelsHaveDistinctLocalEnvironments() {
    #expect(LocalModel.allCases.count == 2)
    #expect(LocalModel.inklingMini.pythonPath != LocalModel.gemma12B.pythonPath)
    #expect(LocalModel.inklingMini.modelPath != LocalModel.gemma12B.modelPath)
    #expect(LocalModel.inklingMini.script == LocalModel.gemma12B.script)
    var settings = BackendSettings()
    #expect(settings.localModel == .inklingMini)
    settings.mode = .gemma
    #expect(settings.label == "Gemma 4 12B")
    settings.mode = .compatible
    #expect(settings.localModel == nil)
}

@Test func conversationRemembersItsLocalModel() throws {
    var chat = Conversation(); chat.localModel = .gemma12B
    let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat))
    #expect(restored.localModel == .gemma12B)
    let legacy = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(Conversation()))
    #expect(legacy.localModel == nil)
}

@Test func legacyRoutesAndExplicitChoicesSurviveRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = ChatStorage(directory: directory)
    var state = SavedState()
    state.version = 1
    var local = Conversation()
    local.localModel = .gemma12B
    var server = Conversation()
    server.messages = [Message(role: .assistant, text: "Example", model: "Fixture server")]
    state.conversations = [local, server, Conversation()]
    try storage.save(state)
    var migrated = try storage.load()
    #expect(migrated.conversations.map(\.route) == [.gemma, .compatible, nil])
    migrated.conversations[0].route = .compatible
    migrated.conversations[1].route = .inkling
    try storage.save(migrated)
    #expect(try storage.load().conversations.map(\.route) == [.compatible, .inkling, nil])
}

@Test func futureLibraryPreservedEvenWithDifferentSchema() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storage = ChatStorage(directory: directory)
    let data = Data(#"{"version":99}"#.utf8)
    try data.write(to: storage.fileURL)
    #expect(throws: ChatError.self) { try storage.load() }
    #expect(try Data(contentsOf: storage.fileURL) == data)
}
