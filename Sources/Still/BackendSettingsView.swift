import AppKit
import SwiftUI
import StillCore

struct BackendSettingsView: View {
    let store: ChatStore
    @State private var settings = BackendSettings()
    @State private var apiKey = ""
    @State private var originalKey = ""
    @State private var status = ""
    @State private var testing = false
    @State private var saving = false
    @State private var saveError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Default model", selection: $settings.mode) {
                        Text("Inkling 2 Mini · on this Mac").tag(BackendMode.inkling)
                        Text("Gemma 4 12B · on this Mac").tag(BackendMode.gemma)
                        Text("Compatible server").tag(BackendMode.compatible)
                    }
                } header: {
                    Text("New chats").font(StillTypography.minimum.weight(.semibold))
                }
                Section {
                    TextField("Name", text: $settings.displayName)
                    TextField("Base URL", text: $settings.baseURL).textContentType(.URL)
                    TextField("Model ID", text: $settings.model)
                    SecureField("API key (optional)", text: $apiKey)
                    Text("Works with OpenAI-compatible chat servers, including llama.cpp and LM Studio. Messages go to the server you choose. Keys stay in Keychain.").foregroundStyle(.secondary)
                    Button(testing ? "Checking…" : "Test connection") { test() }.disabled(testing)
                    if !status.isEmpty { Text(status) }
                } header: {
                    Text("Compatible server").font(StillTypography.minimum.weight(.semibold))
                }
                Section {
                    LabeledContent("Status", value: store.runtime.status)
                    Button("Unload model") { store.runtime.unload() }.disabled(store.busy || !store.runtime.canUnload)
                } header: {
                    Text("Local runtime").font(StillTypography.minimum.weight(.semibold))
                }
                Section {
                    TextField("Instructions", text: $settings.systemPrompt, axis: .vertical).lineLimit(3...6)
                    Text("Chats are saved on this Mac.").foregroundStyle(.secondary)
                } header: {
                    Text("Instructions for all chats").font(StillTypography.minimum.weight(.semibold))
                }
                Section {
                    HStack {
                        Button("Show saved chats") { NSWorkspace.shared.open(store.storage.directory) }
                        Button("Show runtime log") {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Still"))
                        }
                    }
                }
            }.formStyle(.grouped).disabled(testing || saving)
            HStack {
                if let saveError {
                    Text(saveError).foregroundStyle(.orange)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.writable || !store.isRestored || testing || saving)
            }.padding(20)
        }.frame(width: 550, height: 620)
            .background {
                SettingsEscapeHandler { window in save(closing: window) }
            }
            .onAppear { settings = store.state.settings; loadKey() }
            .onChange(of: store.isRestored) { _, ready in
                if ready { settings = store.state.settings; loadKey() }
            }
            .onChange(of: settings.baseURL) { _, _ in loadKey(); status = "" }
            .onChange(of: settings.model) { _, _ in status = "" }
    }

    private func save(closing window: NSWindow? = nil) {
        guard !saving else { return }
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            do {
                try await store.saveSettings(settings, apiKey: originalKey == apiKey ? nil : apiKey)
                originalKey = apiKey
                status = "Saved"
                if let window, window.isVisible { window.performClose(nil) }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func loadKey() {
        var connection = settings
        connection.model = "key lookup"
        originalKey = (try? connection.validatedEndpoint()).map { Keychain.read(account: $0.absoluteString) } ?? ""
        apiKey = originalKey
    }
    private func test() {
        testing = true; status = ""
        Task {
            defer { testing = false }
            do {
                let endpoint = try settings.validatedEndpoint()
                var request = URLRequest(url: endpoint.appendingPathComponent("models")); request.timeoutInterval = 10
                if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw ChatError.message("The server did not accept the connection.") }
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let models = json?["data"] as? [[String: Any]] ?? []
                status = models.contains { $0["id"] as? String == settings.model } ? "Connected · model found" : "Connected · check the model ID"
            } catch { status = error.localizedDescription }
        }
    }
}

private struct SettingsEscapeHandler: NSViewRepresentable {
    let onEscape: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        // Handle Escape before a focused text field can consume it.
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = view?.window, event.window === window else { return event }
            if !event.isARepeat { coordinator?.onEscape?(window) }
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var onEscape: ((NSWindow) -> Void)?
        var monitor: Any?
    }
}
