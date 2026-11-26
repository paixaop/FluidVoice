import Foundation

@MainActor
final class DictationCaptureTranscript {
    struct Finalized {
        let text: String
        let conversation: String
    }

    struct Checkpoint {
        let entry: CaptureLog.DictationEntry
        let result: Task<Finalized, Never>
    }

    private(set) var segmentStart = 0
    private(set) var latestCheckpoint: Task<Finalized, Never>?
    private(set) var conversation = ""
    private(set) var pendingCheckpoints = 0
    private let log: CaptureLog
    private var entry: CaptureLog.DictationEntry
    private var preview = ""
    private var previewEnd = 0
    private var closed = false
    private var suspended = false

    init(log: CaptureLog = .shared) {
        self.log = log
        self.entry = log.beginDictation()
    }

    var hasScreenshots: Bool {
        self.latestCheckpoint != nil
    }

    func publishPreview(_ text: String, from start: Int, through end: Int) {
        guard !self.closed, !self.suspended, start == self.segmentStart, end >= self.previewEnd else { return }
        self.previewEnd = end
        guard self.preview != text else { return }
        self.preview = text
        self.log.writeDictation(text, to: self.entry)
    }

    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended, !self.closed else { return }
        self.suspended = suspended
        if suspended {
            self.preview = ""
            self.log.writeDictation("", to: self.entry)
        }
    }

    func checkpoint(transcribe: @escaping @MainActor () async -> (end: Int, text: String?)) -> Checkpoint {
        let previous = self.latestCheckpoint
        let preview = self.preview
        let previewEnd = self.previewEnd
        self.pendingCheckpoints += 1
        let result = Task {
            defer { self.pendingCheckpoints -= 1 }
            let prefix = await previous?.value.conversation ?? ""
            let final = await transcribe()
            self.segmentStart = final.end
            let text = final.text ?? (previewEnd <= final.end ? preview : "")
            let conversation = Self.join(prefix, text)
            self.conversation = conversation
            return Finalized(text: text, conversation: conversation)
        }
        self.latestCheckpoint = result
        return Checkpoint(entry: self.entry, result: result)
    }

    func startNextSegment(at timestamp: Date) {
        self.previewEnd = 0
        self.preview = ""
        self.entry = self.log.beginDictation(at: timestamp)
    }

    func finish(with text: String) {
        guard !self.closed else { return }
        self.closed = true
        self.log.writeDictation(text, to: self.entry)
    }

    func finishTail(with text: String?) {
        self.finish(with: text ?? self.preview)
    }

    func discardPreview() {
        guard !self.closed else { return }
        self.closed = true
        self.log.writeDictation("", to: self.entry)
    }

    static func join(_ prefix: String, _ text: String) -> String {
        [prefix, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
