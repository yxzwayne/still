import Foundation

public struct ChatStorage: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var fileURL: URL { directory.appendingPathComponent("chats.json") }
    public func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SavedState() }
        var state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: fileURL))
        guard state.version == 1 else { throw ChatError.message("This chat library was written by a newer version of Still.") }
        state.recoverInterruptedReplies()
        return state
    }
    public func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}
