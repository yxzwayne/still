import Foundation

public enum LocalModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case inklingMini, gemma12B
    public var id: String { rawValue }
    public var title: String { self == .inklingMini ? "Inkling 2 Mini" : "Gemma 4 12B" }
    public var mode: BackendMode { self == .inklingMini ? .inkling : .gemma }
    public var script: String { "local_server" }
    public var modelPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(self == .inklingMini
            ? ".lmstudio/models/mlx-community/Inkling-2-Mini-4bit"
            : "Library/Application Support/Still/Models/gemma-4-12B-it-4bit")
    }
    public var pythonPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Still")
            .appendingPathComponent(self == .inklingMini ? "Runtime" : "GemmaTextRuntime")
            .appendingPathComponent("bin/python")
    }
}
