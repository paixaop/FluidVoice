import AppKit
import Combine

@MainActor
final class CaptureLog: ObservableObject {
    static let shared = CaptureLog(writer: CaptureLogWriter())
    typealias ScreenshotEntry = Task<CaptureLogWriter.EntryLocation?, Never>

    struct DictationEntry {
        let location: Task<CaptureLogWriter.EntryLocation?, Never>
        let timestamp: Date
    }

    @Published private(set) var errorMessage: String?
    @Published private(set) var isSummarizing = false
    private let writer: CaptureLogWriter
    private var pendingOperation: Task<Void, Never>?

    init(writer: CaptureLogWriter) {
        self.writer = writer
    }

    func record(_ entry: CaptureLogWriter.Entry, at timestamp: Date = .now) {
        guard SettingsStore.shared.captureLogEnabled else { return }
        self.enqueue {
            _ = try await self.writer.append(entry, at: timestamp)
        }
    }

    func beginDictation(at timestamp: Date = .now) -> DictationEntry {
        let location = self.enqueue { try await self.writer.append(.liveDictation, at: timestamp) }
        return DictationEntry(location: location, timestamp: timestamp)
    }

    func writeDictation(_ text: String, to entry: DictationEntry) {
        self.enqueue {
            try await self.writeDictationNow(text, to: entry)
        }
    }

    func recordScreenshot(
        _ png: Task<Data, Error>,
        at timestamp: Date,
        after checkpoint: DictationCaptureTranscript.Checkpoint? = nil
    ) -> ScreenshotEntry {
        let write = self.enqueue { () async throws -> CaptureLogWriter.EntryLocation? in
            if let checkpoint {
                try await self.writeDictationNow(checkpoint.result.value.text, to: checkpoint.entry)
            }
            // ScreenshotCapture reports acquisition failures. They aren't HTML write errors.
            guard let data = try? await png.value else { return nil }
            return try await self.writer.append(.screenshot(data), at: timestamp)
        }
        return Task { await write.value ?? nil }
    }

    private func writeDictationNow(_ text: String, to entry: DictationEntry) async throws {
        if let location = await entry.location.value {
            try await self.writer.writeDictation(text, to: location, at: entry.timestamp)
        }
    }

    func addImageAnalysis(_ markdown: String, to screenshot: ScreenshotEntry?) async {
        guard let entry = await screenshot?.value else { return }
        let write = self.enqueue { try await self.writer.addImageAnalysis(markdown, to: entry) }
        _ = await write.value
    }

    func startNewTranscript() {
        self.enqueue {
            let page = try await self.writer.startNewTranscript()
            SettingsStore.shared.captureLogEnabled = true
            try self.open(page)
        }
    }

    func openPage() {
        self.enqueue {
            try await self.open(self.writer.preparePage())
        }
    }

    func summarizeSavedTranscript() {
        guard !self.isSummarizing else { return }
        self.isSummarizing = true
        Task {
            defer { self.isSummarizing = false }
            do {
                async let captures = self.writer.savedTranscripts()
                async let meetings = MeetingSessionStore.shared.savedHTMLTranscripts()
                let transcripts = try await (captures + meetings).sorted { $0.date > $1.date }
                guard let page = self.chooseTranscript(transcripts) else { return }
                let summary = try await CaptureAI.shared.summarizeTranscript(at: page)
                try await Self.saveSummary(summary, to: page)
                try self.open(page)
            } catch {
                NSApplication.shared.activate()
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn’t Summarize Transcript"
                alert.runModal()
            }
        }
    }

    private func chooseTranscript(_ transcripts: [HTMLText.Transcript]) -> URL? {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = "Summarize Transcript"
        guard !transcripts.isEmpty else {
            alert.informativeText = "No saved capture or meeting transcripts were found."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
        alert.informativeText = "The selected transcript and its screenshots will be sent to OpenAI."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 26), pullsDown: false)
        for transcript in transcripts {
            let date = transcript.date.formatted(date: .abbreviated, time: .standard)
            let title = "\(transcript.title) · \(date)"
            picker.addItem(withTitle: picker.indexOfItem(withTitle: title) == -1 ? title : "\(title) (\(picker.numberOfItems + 1))")
        }
        picker.selectItem(at: 0)
        picker.setAccessibilityLabel("Saved transcript")
        alert.accessoryView = picker
        alert.addButton(withTitle: "Summarize")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, transcripts.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return transcripts[picker.indexOfSelectedItem].url
    }

    @concurrent
    private static func saveSummary(_ summary: String, to page: URL) async throws {
        try HTMLText.writeSummary(summary, to: page)
    }

    func finishPendingWrites() async {
        await self.pendingOperation?.value
    }

    private func open(_ page: URL) throws {
        guard NSWorkspace.shared.open(page) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The capture log couldn’t be opened in your browser."])
        }
    }

    @discardableResult
    private func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) -> Task<T?, Never> {
        let previous = self.pendingOperation
        let task = Task<T?, Never> {
            await previous?.value
            do {
                let result = try await operation()
                if self.errorMessage != nil { self.errorMessage = nil }
                return result
            } catch {
                self.errorMessage = error.localizedDescription
                DebugLogger.shared.error("Capture log update failed: \(error.localizedDescription)", source: "CaptureLog")
                return nil
            }
        }
        self.pendingOperation = Task { _ = await task.value }
        return task
    }
}
