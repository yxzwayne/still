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

    @State private var searchHits: [SearchJump] = []
    @State private var searchJump: SearchJump?
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @FocusState private var chatListFocused: Bool
    @FocusState private var focusedChatID: UUID?


    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let issue = store.storageIssue {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chats aren’t being saved").font(.headline)
                        Text(issue).font(.callout).textSelection(.enabled)
                        HStack {
                            Button("Show Library") { NSWorkspace.shared.activateFileViewerSelecting([store.storage.fileURL]) }
                            Button("Retry") { Task { await store.retryStorage() } }.disabled(!store.isRestored)
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1))
                }
                if let error = store.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { store.error = nil } label: {
                            Image(systemName: "xmark")
                                .frame(width: InteractionMetrics.controlSize, height: InteractionMetrics.controlSize)
                        }
                        .buttonStyle(HoverButtonStyle())
                        .help("Dismiss error")
                        .accessibilityLabel("Dismiss error")
                    }.padding(14).background(.orange.opacity(0.08))
                }
                if searching && !store.search.isEmpty {
                    let hits = searchHits
                    let index = hits.firstIndex { $0.message == searchJump?.message && $0.range == searchJump?.range } ?? 0
                    HStack {
                        Text(hits.isEmpty ? (store.selected?.title.localizedCaseInsensitiveContains(store.search) == true ? "Title match" : "No matches in this chat") : "Match \(index + 1) of \(hits.count)")
                        Spacer()
                        Button("Previous") { searchJump = hits[(index + hits.count - 1) % hits.count] }
                        Button("Next") { searchJump = hits[(index + 1) % hits.count] }
                    }.font(.callout).padding(8).disabled(hits.count < 2)
                }
                if let chat = store.selected, !chat.messages.isEmpty {
                    ChatTranscript(chat: chat, reply: store.activeReply, timing: store.lastReplyTiming,
                                   retry: store.retry, retryModel: store.nextSettings.label, retryAvailable: store.canRetry, searchJump: searchJump)
                        .id(chat.id)
                } else {
                    Text(store.isRestored ? "What’s on your mind?" : "Opening chats…")
                            .font(.system(size: 28, weight: .medium, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ChatComposer(store: store).padding(.vertical, 12)
            }
            .background(surface)
            .navigationTitle(store.selected?.messages.isEmpty == false ? (store.selected?.title ?? "") : "")
            .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Chat actions", systemImage: "ellipsis.circle") {
                        Button("Rename…") { renameText = store.selected?.title ?? ""; renameID = store.state.selectedID }
                        Button("Delete…", role: .destructive) { deleteID = store.state.selectedID }
                    }.disabled(!store.isRestored || !store.writable)
                }
            }
        }
        .tint(accent)
        .task { await store.restore() }
        .onExitCommand { if searching { closeSearch() } }
        .onChange(of: store.selected?.messages.last?.id) {
            if !store.search.isEmpty, let id = store.state.selectedID { revealMatch(in: id) }
        }
        .onChange(of: store.state.selectedID) {
            if !store.search.isEmpty, let id = store.state.selectedID { revealMatch(in: id) }
        }
        .onChange(of: store.search) { if let id = store.state.selectedID { revealMatch(in: id) } }
        .onChange(of: store.newChatEvent) { closeSearch() }
        .sheet(isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename chat").font(.headline)
                TextField("Title", text: $renameText).textFieldStyle(.roundedBorder).onSubmit { commitRename() }
                HStack { Spacer(); Button("Cancel") { renameID = nil }.keyboardShortcut(.cancelAction); Button("Save") { commitRename() }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 360)
        }
        .alert("Delete “\(store.state.conversations.first { $0.id == deleteID }?.title ?? "chat")”?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Cancel", role: .cancel) { deleteID = nil }
            Button("Delete", role: .destructive) { if let id = deleteID { store.delete(id) }; deleteID = nil }
        } message: { Text("This removes the conversation from this Mac.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Still").font(.title2.weight(.semibold))
                .padding(.horizontal, SidebarMetrics.inset + SidebarMetrics.labelInset)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 4) {
                Button { closeSearch(); store.newChat() } label: {
                    sidebarLabel("New Chat", symbol: "square.and.pencil")
                }
                .buttonStyle(HoverButtonStyle(shape: Capsule()))
                .help("New chat (⌘N)")
                Group {
                    if searching {
                        HStack(spacing: SidebarMetrics.iconSpacing) {
                            sidebarIcon("magnifyingglass")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            TextField("Search chats", text: $store.search)
                                .textFieldStyle(.plain)
                                .font(.callout)
                                .focused($searchFocused)
                            Button { closeSearch() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: InteractionMetrics.controlSize, height: InteractionMetrics.controlSize)
                            }
                            .buttonStyle(HoverButtonStyle(shape: Circle()))
                            .help("Close search")
                            .accessibilityLabel("Close search")
                        }
                        .padding(.leading, SidebarMetrics.labelInset)
                        .padding(.trailing, 3)
                        .frame(height: SidebarMetrics.rowHeight)
                        .task {
                            await Task.yield()
                            if searching { searchFocused = true }
                        }
                    } else {
                        Button { searching = true } label: {
                            sidebarLabel("Search", symbol: "magnifyingglass")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(HoverButtonStyle(shape: Capsule()))
                        .keyboardShortcut("f")
                    }
                }
                .modifier(ChatGlass(shape: Capsule()))
            }
            .padding(.horizontal, SidebarMetrics.inset)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.chats) { chat in
                            let isSelected = store.state.selectedID == chat.id
                            Button {
                                store.select(chat.id)
                                revealMatch(in: chat.id)
                            } label: {
                                SidebarRow(chat: chat, search: store.search, isSelected: isSelected,
                                           generating: store.activeReply?.conversationID == chat.id)
                            }
                            .buttonStyle(HoverButtonStyle(shape: Capsule()))
                            .modifier(ChatGlass(shape: Capsule(), tint: accent.opacity(0.18), isVisible: isSelected))
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .focused($focusedChatID, equals: chat.id)
                            .id(chat.id)
                            .contextMenu {
                                Button("Rename…") { renameText = chat.title; renameID = chat.id }
                                Button("Delete…", role: .destructive) { deleteID = chat.id }
                            }
                        }
                    }
                    .padding(.horizontal, SidebarMetrics.inset)
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("Chats")
                .focusable(interactions: .edit)
                .focusEffectDisabled()
                .focused($chatListFocused)
                .onMoveCommand { direction in
                    guard let id = adjacentChatID(in: direction) else { return }
                    store.select(id, focusComposer: false)
                    revealMatch(in: id)
                    proxy.scrollTo(id)
                    if focusedChatID != nil { focusedChatID = id }
                }
                .overlay {
                    if store.isRestored && !store.search.isEmpty && store.chats.isEmpty {
                        Text("No matching chats").foregroundStyle(.secondary).font(.callout)
                    }
                }
                .onChange(of: store.state.conversations.count) { _, _ in
                    if let id = store.state.selectedID { proxy.scrollTo(id, anchor: .top) }
                }
            }

            SettingsLink {
                sidebarLabel("Settings", symbol: "gearshape")
            }
            .buttonStyle(HoverButtonStyle(shape: Capsule()))
            .foregroundStyle(.secondary)
            .padding(.horizontal, SidebarMetrics.inset)
            .padding(.bottom, 16)
        }
        .disabled(!store.isRestored || !store.writable)
        .navigationTitle("Still")
    }

    private func sidebarLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: SidebarMetrics.iconSpacing) {
            sidebarIcon(symbol).accessibilityHidden(true)
            Text(title).font(.callout)
        }
        .padding(.horizontal, SidebarMetrics.labelInset)
        .frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight, alignment: .leading)
    }

    private func sidebarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 18)
    }

    private func adjacentChatID(in direction: MoveCommandDirection) -> UUID? {
        guard chatListFocused || focusedChatID != nil else { return nil }
        let chats = store.chats
        let currentID = focusedChatID ?? store.state.selectedID
        let index = chats.firstIndex { $0.id == currentID }
        switch direction {
        case .up:
            guard let index else { return chats.last?.id }
            return index > chats.startIndex ? chats[index - 1].id : nil
        case .down:
            guard let index else { return chats.first?.id }
            return index + 1 < chats.endIndex ? chats[index + 1].id : nil
        default: return nil
        }
    }

    private var matches: [SearchJump] {
        guard let chat = store.selected, !store.search.isEmpty else { return [] }
        return chat.messages.flatMap { message in
            var hits: [SearchJump] = []
            var start = message.text.startIndex
            while start < message.text.endIndex, let range = message.text.range(of: store.search, options: .caseInsensitive, range: start..<message.text.endIndex, locale: .current), range.upperBound > start {
                hits.append(SearchJump(conversation: chat.id, message: message.id, range: range))
                start = range.upperBound
            }
            return hits
        }
    }

    private func revealMatch(in id: UUID) {
        guard id == store.state.selectedID else { return }
        searchHits = matches
        searchJump = searchHits.first
    }

    private func closeSearch() {
        searchHits = []
        searchJump = nil
        store.search = ""
        searching = false
        searchFocused = false
        store.focusComposer()
    }

    private func commitRename() {
        if let id = renameID { store.rename(id, to: renameText) }
        renameID = nil
        store.focusComposer()
    }
}

private enum SidebarMetrics {
    static let inset: CGFloat = 10
    static let labelInset: CGFloat = 10
    static let iconSpacing: CGFloat = 7
    static let rowHeight: CGFloat = 32
}

private struct SidebarRow: View {
    let chat: Conversation
    let search: String
    let isSelected: Bool
    let generating: Bool

    private var excerpt: Text? {
        guard !search.isEmpty, !chat.title.localizedCaseInsensitiveContains(search) else { return nil }
        for message in chat.messages.reversed() {
            let source = message.text.replacingOccurrences(of: "\n", with: " ")
            let text = (try? AttributedString(markdown: source)).map { String($0.characters) } ?? source
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if let excerpt { excerpt.font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if generating { ProgressView().controlSize(.mini).accessibilityLabel("Replying") }
        }
        .help(chat.title)
        .padding(.horizontal, SidebarMetrics.labelInset)
        .padding(.vertical, 3)
        .frame(minHeight: SidebarMetrics.rowHeight)
    }
}

private struct SearchJump: Identifiable {
    let id = UUID()
    let conversation: UUID
    let message: UUID
    let range: Range<String.Index>
}

private extension EnvironmentValues {
    @Entry var retryModelName = ""
    @Entry var activeSearchHit: SearchJump? = nil
}

private struct ChatTranscript: View {
    let chat: Conversation
    let reply: LiveReply?
    let timing: ReplyTiming?
    let retry: () -> Void
    let retryModel: String
    let retryAvailable: Bool
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
                            canRetry: retryAvailable && message.id == chat.messages.last?.id
                        )
                        .environment(\.retryModelName, retryModel)
                        .environment(\.activeSearchHit, searchJump?.message == message.id ? searchJump : nil)
                        .id(message.id)
                    }
                    Color.clear.frame(height: 8).id("latest").accessibilityHidden(true)
                }
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
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(searchJump.id, anchor: .center)
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
                guard following else { return }
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
                .animation(reduceMotion ? nil : InteractionMotion.reveal, value: following)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ChatStore
    @State private var editorHeight = SubmitTextView.singleLineHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.selected != nil && store.selected?.route == nil {
                Text("Choose a model before sending to this saved chat.").font(.callout)
            }
            if store.selected?.route == .compatible && !store.routeReady {
                HStack {
                    Text("Set up the server to send here.")
                    SettingsLink { Text("Open Settings") }
                }.font(.callout)
            }
            if store.draft.utf8.count > 48000 { Text("Shorten this message to 48,000 UTF-8 bytes to send.").font(.callout) }
            if let reply = store.activeReply, !store.replyingHere {
                Button { store.select(reply.conversationID) } label: {
                    Label("Send is paused · View the running reply", systemImage: "arrow.up.right")
                        .padding(.horizontal, 6)
                        .frame(minHeight: InteractionMetrics.controlSize)
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
                    ModelChooser(store: store)
                    sendButton
                        .layoutPriority(1)
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
                .animation(reduceMotion ? nil : InteractionMotion.symbol, value: busy)
                .frame(width: InteractionMetrics.controlSize, height: InteractionMetrics.controlSize)
                .foregroundStyle(enabled ? Color.white : .secondary)
        }
        .buttonStyle(HoverButtonStyle(shape: Circle(), tint: .black, fill: enabled ? accent : .primary.opacity(0.07)))
        .disabled(!enabled)
        .help(busy ? "Stop reply (⌘.)" : "Send (Return) · New line (⇧Return)")
        .accessibilityLabel(label)
    }
}

private struct ModelChooser: View {
    let store: ChatStore
    @State private var open = false
    @State private var keyMonitor: Any?
    @State private var cursor: BackendMode?
    @FocusState private var focused: BackendMode?
    @FocusState private var triggerFocused: Bool
    private var route: BackendMode? { store.selected?.route }
    private func label(_ mode: BackendMode) -> String {
        var settings = store.state.settings
        settings.mode = mode
        return (mode == .compatible ? "Server" : "On this Mac") + " · " + settings.label
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(route.map(label) ?? "Choose model").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.callout).padding(.horizontal, 8).frame(maxWidth: 240).frame(height: InteractionMetrics.controlSize)
        }
        .buttonStyle(HoverButtonStyle(shape: Capsule(), isSelected: open))
        .onChange(of: store.chooserEvent) { open.toggle() }
        .focused($triggerFocused)
        .disabled(!store.isRestored)
        .help("Choose the model for the next message (⇧⌘M)")
        .popover(isPresented: $open) {
            VStack(spacing: 2) {
                ForEach(BackendMode.allCases, id: \.self) { mode in
                    Button { store.selectRoute(mode); open = false } label: {
                        HStack {
                            Text(label(mode)).lineLimit(1)
                            Spacer()
                            if route == mode { Image(systemName: "checkmark") }
                        }.padding(.horizontal, 8).frame(height: 32)
                    }
                    .buttonStyle(HoverButtonStyle(shape: RoundedRectangle(cornerRadius: 6), isSelected: route == mode))
                    .overlay {
                        if cursor == mode { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
                    }
                    .focusable(interactions: .edit)
                    .focused($focused, equals: mode)
                    .accessibilityAddTraits(route == mode ? .isSelected : [])
                }
            }.padding(6).frame(width: 250)
            .onAppear {
                focused = route ?? .inkling
                cursor = nil
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard open, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                    let modes = BackendMode.allCases
                    let index = modes.firstIndex(of: cursor ?? focused ?? route ?? .inkling) ?? 0
                    switch event.keyCode {
                    case 125, 126:
                        let offset = event.keyCode == 125 ? 1 : modes.count - 1
                        cursor = modes[(index + offset) % modes.count]
                        focused = cursor
                    case 36, 76:
                        store.selectRoute(modes[index])
                        open = false
                    case 53:
                        open = false
                    default:
                        return event
                    }
                    return nil
                }
            }
            .onChange(of: focused) { if cursor != nil { cursor = focused } }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
            .onExitCommand { open = false }
        }
        .onChange(of: open) { if !open { triggerFocused = true } }
        .onChange(of: store.state.selectedID) { open = false }
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
    var tint: Color? = nil
    var isVisible = true

    func body(content: Content) -> some View {
        if !isVisible {
            content
        } else if #available(macOS 26, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else if let tint {
            content.background(tint, in: shape)
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
    @Environment(\.retryModelName) private var retryModel
    @Environment(\.activeSearchHit) private var searchHit
    @ViewBuilder private var searchableText: some View {
        if let hit = searchHit, hit.message == message.id,
           hit.range.upperBound <= message.text.endIndex {
            let text = message.text
            let lineStart = text[..<hit.range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text[hit.range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            VStack(alignment: .leading, spacing: 0) {
                if lineStart > text.startIndex {
                    Text(String(text[..<text.index(before: lineStart)]))
                }
                Text(AttributedString(String(text[lineStart..<hit.range.lowerBound])) +
                     highlight(String(text[hit.range])) +
                     AttributedString(String(text[hit.range.upperBound..<lineEnd])))
                    .id(hit.id)
                if lineEnd < text.endIndex { Text(String(text[text.index(after: lineEnd)...])) }
            }.textSelection(.enabled)
        } else { Text(message.text) }
    }

    private func highlight(_ text: String) -> AttributedString {
        var match = AttributedString(text)
        match.backgroundColor = .yellow
        match.foregroundColor = .black
        return match
    }
    @State private var reasoningExpanded = false
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
            if message.role == .user {
                searchableText.font(.system(size: 15)).textSelection(.enabled).lineSpacing(4)
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
                                .padding(.horizontal, 6)
                                .frame(minHeight: InteractionMetrics.controlSize)
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
                    Group {
                        if searchHit != nil { searchableText }
                        else { MarkdownContent(text: message.text).equatable() }
                    }
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
                    replyFooter
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var replyFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            if !message.text.isEmpty || canRetry {
                replyActions.fixedSize()
            }
            if let note = message.note {
                Text(note)
                    .foregroundStyle(message.status == .failed ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    private var replyActions: some View {
        HStack(spacing: 4) {
            if !message.text.isEmpty { CopyButton(text: message.text, title: "Copy response") }
            if canRetry {
                Button(action: retry) {
                    Text(message.status == .complete ? "Regenerate" : "Retry").padding(.horizontal, 6)
                        .frame(height: InteractionMetrics.controlSize)
                }
                .buttonStyle(HoverButtonStyle())
                .help("\(message.status == .complete ? "Regenerate" : "Retry") with \(retryModel)")
            }
        }
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
    private struct Block { var text: String; var level = 0; var marker: String?; var quote = false; var indent = 0; var table: [String]? }
    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { result.append(Block(text: paragraph.joined(separator: "\n"))); paragraph.removeAll() } }
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line.contains("|"), index < lines.count, lines[index].contains("-"),
               lines[index].contains("|"), lines[index].allSatisfy({ "|:- ".contains($0) }) {
                flush()
                var rows = [line]
                index += 1
                while index < lines.count && lines[index].contains("|") {
                    rows.append(lines[index])
                    index += 1
                }
                result.append(Block(text: "", table: rows))
                continue
            }
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
                flush()
                if let last = result.indices.last, result[last].quote { result[last].text += "\n" + trimmed.dropFirst(2) }
                else { result.append(Block(text: String(trimmed.dropFirst(2)), quote: true)) }
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
                if let rows = block.table {
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                GridRow {
                                    ForEach(Array(row.trimmingCharacters(in: CharacterSet(charactersIn: " |")).components(separatedBy: "|").enumerated()), id: \.offset) { _, cell in
                                        Text(.init(cell.trimmingCharacters(in: .whitespaces)) as LocalizedStringKey)
                                            .fontWeight(index == 0 ? .semibold : .regular)
                                    }
                                }
                            }
                        }.textSelection(.enabled).padding(8)
                    }.scrollIndicators(.visible)
                } else {
                HStack(alignment: .top, spacing: 10) {
                    if let marker = block.marker { Text(marker).foregroundStyle(.secondary).frame(minWidth: 15, alignment: .leading) }
                    if block.quote { RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.3)).frame(width: 3) }
                    Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .accessibilityAddTraits(block.level > 0 ? .isHeader : [])
                        .font(.system(size: block.level == 1 ? 21 : block.level == 2 ? 18 : block.level > 0 ? 16 : 15, weight: block.level > 0 ? .semibold : .regular))
                        .foregroundStyle(block.quote ? Color.secondary : Color.primary)
                        .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, CGFloat(min(block.indent, 24)) * 6)
                .fixedSize(horizontal: false, vertical: true).padding(.top, block.level > 0 ? 7 : 0)
                }
            }
        }
    }
}

struct CodeBlock: View {
    let text: String
    @State private var overflows = false
    var language: String { text.components(separatedBy: "\n").first ?? "" }
    var code: String { text.contains("\n") ? String(text.dropFirst(language.count + 1)).trimmingCharacters(in: .newlines) : text }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                if overflows {
                    Image(systemName: "arrow.left.and.right")
                        .help("Scroll horizontally to read the full line")
                        .accessibilityLabel("Code scrolls horizontally")
                }
                Spacer(minLength: 4)
                CopyButton(text: code, title: "Copy code").fixedSize()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 5)
            Divider().opacity(0.4)
            ScrollView(.horizontal) { Text(code).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
            .scrollIndicators(.visible)
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width > $0.containerSize.width + 1 } action: { _, value in overflows = value }
        }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
    }
}

private struct CopyButton: View {
    let text: String
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmation: Int?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(text, forType: .string) { confirmation = pasteboard.changeCount }
        } label: {
            Image(systemName: confirmation == nil ? "doc.on.doc" : "checkmark")
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : InteractionMotion.symbol, value: confirmation != nil)
                .frame(width: InteractionMetrics.controlSize, height: InteractionMetrics.controlSize)
        }
        .buttonStyle(HoverButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(confirmation == nil ? "" : "Copied")
        .help(confirmation == nil ? title : "Copied")
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
