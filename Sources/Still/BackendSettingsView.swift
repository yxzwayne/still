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
            }.formStyle(.grouped).disabled(testing)
            HStack {
                Spacer()
                Button("Save") {
                    do { try store.saveSettings(settings, apiKey: originalKey == apiKey ? nil : apiKey); originalKey = apiKey; status = "Saved" }
                    catch { status = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(!store.writable || !store.isRestored || testing)
            }.padding(20)
        }.frame(width: 550, height: 620)
            .onAppear { settings = store.state.settings; loadKey() }
            .onChange(of: store.isRestored) { _, ready in
                if ready { settings = store.state.settings; loadKey() }
            }
            .onChange(of: settings.baseURL) { _, _ in loadKey(); status = "" }
            .onChange(of: settings.model) { _, _ in status = "" }
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
