import AppKit
import SwiftUI

enum UITiming {
    nonisolated private static let output: FileHandle? = {
        guard let destination = ProcessInfo.processInfo.environment["STILL_UI_TIMING"] else { return nil }
        if destination == "1" { return .standardError }
        guard destination.hasPrefix("/") else { return nil }
        if !FileManager.default.fileExists(atPath: destination) {
            FileManager.default.createFile(atPath: destination, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: destination)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    nonisolated static var enabled: Bool { output != nil }
    private static var launch = ContinuousClock.now
    private static var composerReady = false

    static func startLaunch() { launch = .now }

    static func markComposerReady() {
        guard enabled, !composerReady else { return }
        composerReady = true
        record("composer_ready", since: launch)
    }

    nonisolated static func record(_ event: String, since start: ContinuousClock.Instant, replyID: UUID? = nil) {
        guard let output else { return }
        let elapsed = (ContinuousClock.now - start).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        let identifier = replyID.map { " reply=\($0)" } ?? ""
        let line = "still_ui \(event) ms=\(String(format: "%.3f", milliseconds))\(identifier)\n"
        try? output.write(contentsOf: Data(line.utf8))
    }
}

final class ReplyTiming {
    nonisolated let id: UUID
    nonisolated let started: ContinuousClock.Instant
    private var drewAnswer = false

    init(id: UUID, started: ContinuousClock.Instant) {
        self.id = id
        self.started = started
    }

    nonisolated func receivedText() {
        UITiming.record("first_answer_delta", since: started, replyID: id)
    }

    func drewText() {
        guard !drewAnswer else { return }
        drewAnswer = true
        UITiming.record("first_answer_draw", since: started, replyID: id)
    }
}

// A display-pass marker beside the first answer text. This times drawing, not display scanout.
struct AnswerDrawMarker: NSViewRepresentable {
    let timing: ReplyTiming

    func makeNSView(context: Context) -> MarkerView { MarkerView(timing: timing) }
    func updateNSView(_ view: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        let timing: ReplyTiming

        init(timing: ReplyTiming) {
            self.timing = timing
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            timing.drewText()
        }
    }
}
