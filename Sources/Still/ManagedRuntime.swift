import Foundation
import Darwin
import Observation
import StillCore

@Observable final class ManagedRuntime {
    private(set) var status = "On demand"
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var logHandle: FileHandle?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    static let port = 18765
    static let endpoint = URL(string: "http://127.0.0.1:\(port)/v1")!
    @ObservationIgnored private var loadedModel: LocalModel?
    @ObservationIgnored private var retiring: [Process] = []

    func ready(_ model: LocalModel) async throws {
        idleTask?.cancel()
        if loadedModel == model, let child = process, child.isRunning, await healthIsOurs(model) {
            try Task.checkCancellation()
            if process === child { status = "Ready"; return }
        }
        try Task.checkCancellation()
        let modelPath = model.modelPath.path
        let pythonPath = model.pythonPath.path
        guard FileManager.default.isExecutableFile(atPath: pythonPath), FileManager.default.fileExists(atPath: modelPath + "/model.safetensors.index.json") else {
            throw ChatError.message("\(model.title)’s local files are missing. Restore its runtime and model, or choose another model.")
        }
        guard let script = Bundle.main.url(forResource: model.script, withExtension: "py") else { throw ChatError.message("The app’s local runner is missing. Rebuild Still.") }
        unload()
        // Wait for the previous GPU owner before starting another model.
        for child in retiring {
            for _ in 0..<50 where child.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                for _ in 0..<20 where child.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            }
            guard !child.isRunning else { throw ChatError.message("The previous model is still closing. Try again in a moment.") }
        }
        try Task.checkCancellation()
        retiring.removeAll()
        status = "Starting…"
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Still")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("runtime.log")
        // Each process starts a fresh diagnostic log; prompts are never logged by the app.
        try Data().write(to: logURL, options: .atomic)
        logHandle = try FileHandle(forWritingTo: logURL)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: pythonPath)
        child.arguments = [script.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier), "--model", modelPath, "--port", String(Self.port), "--profile", model.rawValue]
        child.standardOutput = logHandle; child.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        child.environment = environment
        try child.run(); process = child; loadedModel = model
        do {
            for _ in 0..<120 {
                try Task.checkCancellation()
                guard child.isRunning else { throw ChatError.message("The local runner could not start. Check the runtime log from Settings.") }
                if await healthIsOurs(model) {
                    try Task.checkCancellation()
                    guard process === child else { throw CancellationError() }
                    status = "Ready"
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw ChatError.message("The local runner took too long to start. Try again.")
        } catch {
            if process === child { unload() }
            throw error
        }
    }

    private func healthIsOurs(_ model: LocalModel) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/still/health")!)
        request.timeoutInterval = 1
        guard let (data, _) = try? await URLSession.shared.data(for: request), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["app"] as? String == "Still" && object["parent_pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) && object["model"] as? String == model.modelPath.path
    }

    func scheduleUnload() {
        guard process?.isRunning == true else { return }
        status = "Ready"
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)); self?.unload() } catch {}
        }
    }
    func unload() {
        idleTask?.cancel(); idleTask = nil
        if let process, process.isRunning { process.terminate(); retiring.append(process) }
        process = nil; loadedModel = nil
        try? logHandle?.close(); logHandle = nil
        status = "On demand"
    }
}
