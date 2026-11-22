import AppKit
import SwiftUI
import StillCore

struct BackendSettingsView: View {
    let store: ChatStore
    @State private var settings = BackendSettings()
    @State private var apiKey = ""
    @State private var status = ""
    @State private var testing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Backend") {
                    Picker("Run with", selection: $settings.mode) {
                        Text("Inkling 2 Mini · on this Mac").tag(BackendMode.inkling)
                        Text("Gemma 4 12B · on this Mac").tag(BackendMode.gemma)
                        Text("Compatible server").tag(BackendMode.compatible)
                    }
                    if let local = settings.localModel {
                        LabeledContent("Model", value: "\(local.title) · 4-bit MLX")
                        Text("Starts when you send a message. Unloads after five minutes idle or when Still quits.").font(.callout).foregroundStyle(.secondary)
                        Button("Unload model now") { store.runtime.unload() }.disabled(store.busy)
                    } else {
                        TextField("Name", text: $settings.displayName)
                        TextField("Base URL", text: $settings.baseURL).textContentType(.URL)
                        TextField("Model ID", text: $settings.model)
                        SecureField("API key (optional)", text: $apiKey)
                        Text("Works with OpenAI-compatible chat servers, including llama.cpp and LM Studio. Messages go to the server you choose. Keys stay in Keychain.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Conversation") {
                    TextField("Instructions", text: $settings.systemPrompt, axis: .vertical).lineLimit(3...6)
                    Text("Chats are saved on this Mac.").font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Show saved chats") { NSWorkspace.shared.open(store.storage.directory) }
                        Button("Show runtime log") {
                            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Still"))
                        }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                if settings.mode == .compatible { Button(testing ? "Checking…" : "Test connection") { test() }.disabled(testing) }
                Button("Save") {
                    do { try store.saveSettings(settings, apiKey: apiKey); status = "Saved" }
                    catch { status = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(store.busy || !store.isRestored)
            }.padding(20)
        }.frame(width: 550, height: settings.localModel != nil ? 470 : 600)
            .onAppear { settings = store.state.settings; loadKey() }
            .onChange(of: store.isRestored) { _, ready in
                if ready { settings = store.state.settings; loadKey() }
            }
            .onChange(of: settings.baseURL) { _, _ in apiKey = ""; status = "" }
            .onChange(of: settings.mode) { _, _ in loadKey(); status = "" }
    }
    private func loadKey() { if let url = try? settings.validatedEndpoint() { apiKey = Keychain.read(account: url.absoluteString) } }
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
