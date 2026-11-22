import Foundation

public struct ChatStorage: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var fileURL: URL { directory.appendingPathComponent("chats.json") }
    public func load() throws -> SavedState {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return SavedState() }
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard (1...2).contains(version) else { throw ChatError.message("This chat library was written by a newer version of Still.") }
        var state = try JSONDecoder().decode(SavedState.self, from: data)
        state.version = 2
        for index in state.conversations.indices where state.conversations[index].route == nil {
            let chat = state.conversations[index]
            if let local = chat.localModel {
                state.conversations[index].route = local.mode
            } else if let author = chat.messages.last(where: { $0.role == .assistant })?.model,
                      !LocalModel.allCases.contains(where: { $0.title == author }) {
                state.conversations[index].route = .compatible
            }
        }
        state.recoverInterruptedReplies()
        return state
    }
    public func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
