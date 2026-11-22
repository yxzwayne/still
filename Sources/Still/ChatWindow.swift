import AppKit
import SwiftUI
import StillCore

private let accent = Color(red: 0.22, green: 0.41, blue: 0.35)
private let surface = Color(nsColor: .textBackgroundColor)

struct ChatWindow: View {
    @Bindable var store: ChatStore
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var deleteID: UUID?

    @State private var searchJump: SearchJump?
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var composerHeight: CGFloat = 86

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { store.error = nil } label: {
                            Image(systemName: "xmark").frame(width: 22, height: 22)
                        }
                        .buttonStyle(HoverButtonStyle())
                        .help("Dismiss error")
                        .accessibilityLabel("Dismiss error")
                    }.padding(14).background(.orange.opacity(0.08))
                }
                if let chat = store.selected, !chat.messages.isEmpty {
                    ChatTranscript(chat: chat, reply: store.activeReply, timing: store.lastReplyTiming,
                                   retry: store.retry, composerHeight: composerHeight, searchJump: searchJump)
                        .id(chat.id)
                        .overlay(alignment: .bottom) {
                            ChatComposer(store: store)
                                .padding(.bottom, 12)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                        }
                } else {
                    VStack(spacing: 18) {
                        Text("What’s on your mind?")
                            .font(.system(size: 28, weight: .medium, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                        ChatComposer(store: store)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(surface)
            .navigationTitle(store.selected?.messages.isEmpty == false ? (store.selected?.title ?? "") : "")
            .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ChatModelMenuItems(store: store)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: store.state.settings.localModel != nil ? "desktopcomputer" : "network")
                            Text(store.state.settings.label).font(.callout)
                        }
                    }
                    .disabled(!store.isRestored)
                    .help(store.state.settings.localModel == nil ? "Server · Model and backend" : "On this Mac · Model and backend")
                }
            }
        }
        .tint(accent)
        .task { await store.restore() }
        .onExitCommand {
            if searching { closeSearch() }
            else if store.replyingHere { store.stop() }
        }
        .sheet(isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename chat").font(.headline)
                TextField("Title", text: $renameText).textFieldStyle(.roundedBorder).onSubmit { commitRename() }
                HStack { Spacer(); Button("Cancel") { renameID = nil }.keyboardShortcut(.cancelAction); Button("Save") { commitRename() }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 360)
        }
        .alert("Delete this chat?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Cancel", role: .cancel) { deleteID = nil }
            Button("Delete", role: .destructive) { if let id = deleteID { store.delete(id) }; deleteID = nil }
        } message: { Text("This removes the conversation from this Mac.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Still").font(.title2.weight(.semibold))
                .padding(.horizontal, 16).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 2) {
                Button { closeSearch(); store.newChat() } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                        .padding(.horizontal, 6)
                }
                .help("New chat (⌘N)")
                if searching {
                    HStack {
                        TextField("Search chats", text: $store.search)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                        Button { closeSearch() } label: {
                            Image(systemName: "xmark").frame(width: 23, height: 23)
                        }
                        .help("Close search")
                        .accessibilityLabel("Close search")
                    }
                    .padding(.horizontal, 6)
                    .task {
                        await Task.yield()
                        if searching { searchFocused = true }
                    }
                } else {
                    Button { searching = true } label: {
                        Label("Search", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                    .keyboardShortcut("f")
                }
            }
            .buttonStyle(HoverButtonStyle())
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                List(selection: Binding(get: { store.state.selectedID }, set: { id in
                    guard let id else { return }
                    store.select(id)
                    revealMatch(in: id)
                })) {
                    ForEach(store.chats) { chat in
                        SidebarRow(chat: chat, search: store.search,
                                   generating: store.activeReply?.conversationID == chat.id,
                                   isSelected: store.state.selectedID == chat.id)
                            .simultaneousGesture(TapGesture().onEnded { revealMatch(in: chat.id) })
                            .tag(chat.id)
                            .id(chat.id)
                            .contextMenu {
                                Button("Rename…") { renameText = chat.title; renameID = chat.id }
                                Button("Delete…", role: .destructive) { deleteID = chat.id }
                            }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if store.isRestored && !store.search.isEmpty && store.chats.isEmpty {
                        Text("No matching chats").foregroundStyle(.secondary).font(.callout)
                    }
                }
                .onChange(of: store.state.conversations.count) { _, _ in
                    if let id = store.state.selectedID { proxy.scrollTo(id, anchor: .top) }
                }
            }

            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape").font(.callout)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 24)
                }
                .buttonStyle(HoverButtonStyle())
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .disabled(!store.isRestored)
        .navigationTitle("Still")
    }

    private func revealMatch(in id: UUID) {
        guard !store.search.isEmpty,
              let chat = store.chats.first(where: { $0.id == id }),
              let message = chat.messages.last(where: { $0.text.localizedCaseInsensitiveContains(store.search) }) else {
            searchJump = nil
            return
        }
        searchJump = SearchJump(conversation: id, message: message.id)
    }

    private func closeSearch() {
        searchJump = nil
        store.search = ""
        searching = false
        searchFocused = false
        store.focusComposer()
    }

    private func commitRename() {
        if let id = renameID { store.rename(id, to: renameText) }
        renameID = nil
    }
}

private struct SidebarRow: View {
    let chat: Conversation
    let search: String
    let generating: Bool
    let isSelected: Bool

    private var excerpt: Text? {
        guard !search.isEmpty, !chat.title.localizedCaseInsensitiveContains(search) else { return nil }
        for message in chat.messages.reversed() {
            let text = message.text.replacingOccurrences(of: "\n", with: " ")
            if let range = text.range(of: search, options: [.caseInsensitive], locale: .current) {
                let start = text.index(range.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
                let prefix = (start == text.startIndex ? "" : "…") + text[start..<range.lowerBound]
                var match = AttributedString(String(text[range]))
                match.inlinePresentationIntent = .stronglyEmphasized
                return Text(AttributedString(prefix) + match + AttributedString(String(text[range.upperBound...].prefix(60))))
            }
        }
        return nil
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).lineLimit(1)
                if let excerpt { excerpt.font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if generating { Spacer(); ProgressView().controlSize(.mini).accessibilityLabel("Replying") }
        }
        .help(chat.title)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 5)
        .modifier(HoverHighlight(shape: RoundedRectangle(cornerRadius: 6), isSelected: isSelected))
        .padding(.horizontal, -5)
    }
}

private struct SearchJump: Identifiable {
    let id = UUID()
    let conversation: UUID
    let message: UUID
}

private struct ChatTranscript: View {
    let chat: Conversation
    let reply: LiveReply?
    let timing: ReplyTiming?
    let retry: () -> Void
    let composerHeight: CGFloat
    let searchJump: SearchJump?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true
    @State private var scrollPhase = ScrollPhase.idle

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 29) {
                    ForEach(chat.messages) { message in
                        TranscriptRow(
                            message: message,
                            reply: reply?.timing.id == message.id ? reply : nil,
                            timing: timing?.id == message.id ? timing : nil,
                            retry: retry,
                            canRetry: reply == nil && message.id == chat.messages.last?.id
                        )
                        .id(message.id)
                    }
                    Color.clear.frame(height: composerHeight).id("latest").accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 696)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
            }
            .modifier(TranscriptEdge())
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .task(id: searchJump?.id) {
                guard let searchJump, searchJump.conversation == chat.id else { return }
                following = false
                proxy.scrollTo(searchJump.message, anchor: .top)
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                if isUserScrolling(oldPhase) || isUserScrolling(newPhase) {
                    following = nearBottom(context.geometry)
                }
                scrollPhase = newPhase
            }
            .onScrollGeometryChange(for: Bool.self, of: nearBottom) { _, isNearBottom in
                if isUserScrolling(scrollPhase) { following = isNearBottom }
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, _ in
                if following && !isUserScrolling(scrollPhase) { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: chat.messages.last?.id) { _, _ in
                following = true
                proxy.scrollTo("latest", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if !following {
                        Button {
                            following = true
                            proxy.scrollTo("latest", anchor: .bottom)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.callout.weight(.semibold))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(HoverButtonStyle(shape: Circle()))
                        .modifier(ChatGlass(shape: Circle()))
                        .help("Jump to latest message")
                        .accessibilityLabel("Jump to latest message")
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .animation(InteractionMotion.reveal, value: following)
                .padding(.bottom, composerHeight)
                .padding(18)
            }
        }
    }

    private func isUserScrolling(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .decelerating
    }

    private func nearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY <= 44
    }
}

private struct TranscriptRow: View {
    let message: Message
    let reply: LiveReply?
    let timing: ReplyTiming?
    let retry: () -> Void
    let canRetry: Bool

    var body: some View {
        MessageView(message: reply?.message ?? message, phase: reply?.phase ?? "", retry: retry, canRetry: canRetry, timing: timing)
    }
}

private struct ChatComposer: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let store: ChatStore
    @State private var editorHeight = SubmitTextView.singleLineHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reply = store.activeReply, !store.replyingHere {
                Button { store.select(reply.conversationID) } label: {
                    Label("View chat generating a reply", systemImage: "arrow.up.right")
                        .padding(.horizontal, 5).padding(.vertical, 3)
                }
                .buttonStyle(HoverButtonStyle())
                .font(.caption).foregroundStyle(Color(nsColor: .linkColor)).padding(.leading, 3)
            }
            VStack(alignment: .leading, spacing: 8) {
                ComposerTextView(
                    text: Binding(get: { store.draft }, set: store.updateDraft),
                    height: $editorHeight,
                    focusID: store.focusID,
                    onSubmit: store.send
                )
                .frame(height: editorHeight)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Menu {
                        ChatModelMenuItems(store: store)
                    } label: {
                        Text(store.state.settings.label)
                            .font(.callout)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(.primary)
                    .modifier(HoverHighlight(shape: Capsule()))
                    .disabled(!store.isRestored)
                    .help("Select model")
                    .accessibilityLabel("Select model")
                    .accessibilityValue(store.state.settings.label)

                    sendButton
                }
            }
            .padding(9)
            .background(surface, in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.10),
                                   lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(0.045), radius: 6, y: 2)
        }
        .frame(maxWidth: 696)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    private var sendButton: some View {
        let busy = store.replyingHere
        let enabled = busy || store.canSend
        let label = busy ? "Stop reply" : "Send message"
        return Button {
            if busy { store.stop() } else { store.send() }
        } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: busy ? 12 : 16, weight: .semibold))
                .contentTransition(.opacity)
                .animation(InteractionMotion.symbol, value: busy)
                .frame(width: 28, height: 28)
                .background(enabled ? accent : Color.primary.opacity(0.07), in: Circle())
                .foregroundStyle(enabled ? Color.white : .secondary)
        }
        .buttonStyle(HoverButtonStyle(shape: Circle(), tint: .white))
        .disabled(!enabled)
        .help(busy ? "Stop reply (⌘.)" : "Send (Return) · New line (⇧Return)")
        .accessibilityLabel(label)
    }
}

private struct ChatModelMenuItems: View {
    let store: ChatStore

    var body: some View {
        ForEach(LocalModel.allCases) { model in
            Button { store.selectModel(model) } label: {
                if store.state.settings.localModel == model { Label(model.title, systemImage: "checkmark") }
                else { Text(model.title) }
            }.disabled(store.busy)
        }
        if store.state.settings.localModel != nil {
            Divider()
            Text(store.runtime.status)
            Button("Unload Model") { store.runtime.unload() }.disabled(store.busy)
        }
        Divider()
        SettingsLink { Text("Backend Settings…") }
    }
}

private struct TranscriptEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct ChatGlass<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

struct MessageView: View {
    let message: Message
    let phase: String
    let retry: () -> Void
    let canRetry: Bool
    let timing: ReplyTiming?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reasoningExpanded = false
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
            if message.role == .user {
                Text(message.text).font(.system(size: 15)).textSelection(.enabled).lineSpacing(4)
                    .padding(.horizontal, 17).padding(.vertical, 13).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
                    .frame(maxWidth: 580, alignment: .trailing).frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 5) {
                        Text(message.model ?? "Assistant").fontWeight(.medium)
                        if let reasoning = message.reasoning, !reasoning.isEmpty {
                            Button { reasoningExpanded.toggle() } label: {
                                Label {
                                    Text("Reasoning")
                                } icon: {
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(reasoningExpanded ? 90 : 0))
                                }
                                .padding(.horizontal, 5).padding(.vertical, 3)
                            }
                            .buttonStyle(HoverButtonStyle())
                            .accessibilityValue(reasoningExpanded ? "Expanded" : "Collapsed")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if reasoningExpanded, let reasoning = message.reasoning {
                        Text(reasoning).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).padding(.leading, 12)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(.separator).frame(width: 1).allowsHitTesting(false)
                            }
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : InteractionMotion.reveal, value: reasoningExpanded)
                if message.text.isEmpty && message.status == .streaming {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(phase).foregroundStyle(.secondary).font(.callout) }.padding(.vertical, 4)
                } else if !message.text.isEmpty {
                    MarkdownContent(text: message.text).equatable()
                        .overlay(alignment: .topLeading) {
                            if UITiming.enabled, let timing, message.text.contains(where: { !$0.isWhitespace }) {
                                AnswerDrawMarker(timing: timing)
                                    .frame(width: 1, height: 1)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                if message.status != .streaming {
                    HStack(spacing: 4) {
                        if let note = message.note {
                            Text(note).foregroundStyle(message.status == .failed ? Color.orange : Color.secondary)
                                .textSelection(.enabled)
                        }
                        if !message.text.isEmpty { CopyButton(text: message.text) }
                        if canRetry {
                            Button(action: retry) {
                                Label("Retry", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(HoverButtonStyle())
                            .help("Retry last reply")
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

struct MarkdownContent: View, Equatable {
    let text: String
    var body: some View {
        let parts = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 { CodeBlock(text: part) }
                else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    FormattedProse(text: part)
                }
            }
        }
    }
}

struct FormattedProse: View {
    let text: String
    private struct Block { var text: String; var level = 0; var marker: String?; var quote = false; var indent = 0 }
    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { result.append(Block(text: paragraph.joined(separator: "\n"))); paragraph.removeAll() } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") {
                flush(); result.append(Block(text: String(trimmed.dropFirst(hashes + 1)), level: hashes))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); result.append(Block(text: String(trimmed.dropFirst(2)), marker: "•", indent: indent))
            } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); result.append(Block(text: String(trimmed[range.upperBound...]), marker: String(trimmed[range]).trimmingCharacters(in: .whitespaces), indent: indent))
            } else if trimmed.hasPrefix("> ") {
                flush(); result.append(Block(text: String(trimmed.dropFirst(2)), quote: true))
            } else if indent > 0, paragraph.isEmpty, let last = result.indices.last,
                      result[last].marker != nil, indent > result[last].indent {
                result[last].text += "\n" + trimmed
            } else { paragraph.append(line) }
        }
        flush(); return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                HStack(alignment: .top, spacing: 10) {
                    if let marker = block.marker { Text(marker).foregroundStyle(.secondary).frame(minWidth: 15, alignment: .leading) }
                    if block.quote { RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.3)).frame(width: 3) }
                    Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .font(.system(size: block.level == 1 ? 21 : block.level == 2 ? 18 : block.level > 0 ? 16 : 15, weight: block.level > 0 ? .semibold : .regular))
                        .foregroundStyle(block.quote ? Color.secondary : Color.primary)
                        .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, CGFloat(min(block.indent, 24)) * 6)
                .fixedSize(horizontal: false, vertical: true).padding(.top, block.level > 0 ? 7 : 0)
            }
        }
    }
}

struct CodeBlock: View {
    let text: String
    var language: String { text.components(separatedBy: "\n").first ?? "" }
    var code: String { text.contains("\n") ? String(text.dropFirst(language.count + 1)).trimmingCharacters(in: .newlines) : text }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(language.isEmpty ? "Code" : language); Spacer(); CopyButton(text: code) }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
            Divider().opacity(0.4)
            ScrollView(.horizontal) { Text(code).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
    }
}

private struct CopyButton: View {
    let text: String
    @State private var confirmation: Int?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(text, forType: .string) { confirmation = pasteboard.changeCount }
        } label: {
            Image(systemName: confirmation == nil ? "doc.on.doc" : "checkmark")
                .contentTransition(.opacity)
                .animation(InteractionMotion.symbol, value: confirmation != nil)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(HoverButtonStyle())
        .accessibilityLabel(confirmation == nil ? "Copy" : "Copied")
        .help(confirmation == nil ? "Copy" : "Copied")
        .task(id: confirmation) {
            guard let confirmation else { return }
            for _ in 0..<10 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                if NSPasteboard.general.changeCount != confirmation { break }
            }
            self.confirmation = nil
        }
    }
}
