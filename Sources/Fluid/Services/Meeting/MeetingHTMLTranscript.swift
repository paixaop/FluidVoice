import CoreMedia
import Foundation

/// One file per recording. Coalesce ASR revisions so partial captions do not cause a disk write per word.
actor MeetingHTMLTranscript {
    nonisolated static let filename = "transcript.html"

    private let url: URL
    private let title: String
    private let startedAt: Date
    private let captureOrigin: MeetingLiveOriginBox
    private let startedHostTime: CMTime
    private let writeInterval: Duration
    private var latestSnapshot = MeetingLiveTranscriptSnapshot.empty
    private var screenshots: [(hostTime: CMTime, filename: String)] = []
    private var imageAnalyses: [String: String] = [:]
    private var pendingWrite: Task<Void, Never>?
    private var stoppedAt: Date?

    init(
        title: String,
        startedAt: Date,
        directory: URL,
        captureOrigin: MeetingLiveOriginBox,
        startedHostTime: CMTime,
        writeInterval: Duration = .milliseconds(750)
    ) {
        self.url = directory.appendingPathComponent(Self.filename)
        self.title = title
        self.startedAt = startedAt
        self.captureOrigin = captureOrigin
        self.startedHostTime = startedHostTime
        self.writeInterval = writeInterval
    }

    func start(with snapshot: MeetingLiveTranscriptSnapshot) throws {
        guard self.stoppedAt == nil else { return }
        self.accept(snapshot)
        try self.writePage()
    }

    func update(_ snapshot: MeetingLiveTranscriptSnapshot) {
        guard self.stoppedAt == nil, snapshot.revision > self.latestSnapshot.revision else { return }
        let contentChanged = snapshot.utterances != self.latestSnapshot.utterances ||
            snapshot.partials != self.latestSnapshot.partials || snapshot.availability != self.latestSnapshot.availability
        self.accept(snapshot)
        if contentChanged { self.scheduleWrite() }
    }

    @discardableResult
    func addScreenshot(_ png: Data, capturedAt hostTime: CMTime) throws -> URL? {
        guard self.stoppedAt == nil else { return nil }
        let directory = self.url.deletingLastPathComponent().appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).png"
        let file = directory.appendingPathComponent(filename)
        try png.write(to: file, options: .atomic)
        self.screenshots.append((hostTime, filename))
        self.scheduleWrite()
        return file
    }

    func addImageAnalysis(_ markdown: String, for screenshot: URL) throws {
        let filename = screenshot.lastPathComponent
        guard self.screenshots.contains(where: { $0.filename == filename }) else { return }
        if self.stoppedAt == nil {
            self.imageAnalyses[filename] = HTMLText.imageAnalysis(markdown)
            self.scheduleWrite()
        } else if FileManager.default.fileExists(atPath: self.url.path) {
            // Update only the existing screenshot slot. Captions and timestamps are sealed.
            try HTMLText.withTranscriptLock(in: self.url.deletingLastPathComponent()) {
                try HTMLText.writeImageAnalysis(markdown, id: filename, to: self.url)
            }
        }
    }

    private func scheduleWrite() {
        guard self.pendingWrite == nil else { return }
        self.pendingWrite = Task { [weak self, writeInterval = self.writeInterval] in
            do { try await Task.sleep(for: writeInterval) } catch { return }
            await self?.writePendingPage()
        }
    }

    /// Seal the capture timeline. A pending result can still fill an existing screenshot’s analysis slot.
    func finish(with snapshot: MeetingLiveTranscriptSnapshot, stoppedAt: Date) throws -> URL? {
        guard self.stoppedAt == nil else { return nil }
        self.stoppedAt = stoppedAt
        self.pendingWrite?.cancel()
        self.pendingWrite = nil
        self.accept(snapshot)
        try self.writePage()
        let origin = self.captureOrigin.current ?? self.startedHostTime
        let attachments = self.screenshots.map {
            CaptureTimelineImage(
                fileName: $0.filename,
                seconds: MeetingLiveTimeConversion.sessionSeconds(pts: $0.hostTime, origin: origin)
            )
        }.sorted { $0.seconds < $1.seconds }
        do {
            let manifest = self.url.deletingLastPathComponent().appendingPathComponent(CaptureTimelineImage.manifest)
            try JSONEncoder().encode(attachments).write(to: manifest, options: .atomic)
        } catch {
            DebugLogger.shared.warning("Could not save the screenshot timeline: \(error.localizedDescription)", source: "MeetingHTMLTranscript")
        }
        return self.url
    }

    private func accept(_ snapshot: MeetingLiveTranscriptSnapshot) {
        if snapshot.revision >= self.latestSnapshot.revision { self.latestSnapshot = snapshot }
    }

    private func writePendingPage() {
        self.pendingWrite = nil
        guard self.stoppedAt == nil else { return }
        do { try self.writePage() } catch {
            DebugLogger.shared.warning("Could not update the meeting HTML transcript: \(error.localizedDescription)", source: "MeetingHTMLTranscript")
        }
    }

    private func writePage() throws {
        let snapshot = self.latestSnapshot
        let title = HTMLText.escape(self.title)
        let started = Self.dateElement(self.startedAt)
        let status = self.stoppedAt.map { "Stopped \(Self.dateElement($0))" } ?? "Recording"

        let note = switch snapshot.availability {
        case .available: ""
        case let .unavailable(reason), let .degraded(reason): "<p>\(HTMLText.escape(reason))</p>"
        }

        let finalIDs = Set(snapshot.utterances.map(\.id))
        var captions = snapshot.utterances.map { (start: $0.start, speaker: $0.speaker, text: $0.text, partial: false) }
        captions += snapshot.partials.compactMap { speaker, partial in
            guard !finalIDs.contains(partial.id) else { return nil }
            return (start: partial.start, speaker: speaker, text: partial.text, partial: true)
        }
        var rows: [(seconds: TimeInterval, html: String)] = captions.map { row in
            let time = Self.elapsedTimeElement(row.start)
            let source = row.speaker.sourceLabel
            let partial = row.partial ? " <span class=\"partial\">Partial</span>" : ""
            return (row.start, """
            <li><div class="line">\(time) <strong>\(source)</strong>\(partial)</div>
            <p>\(HTMLText.escape(row.text))</p></li>
            """)
        }
        let origin = self.captureOrigin.current ?? self.startedHostTime
        rows += self.screenshots.map { image in
            let seconds = MeetingLiveTimeConversion.sessionSeconds(pts: image.hostTime, origin: origin)
            let time = Self.elapsedTimeElement(seconds)
            let timeText = MeetingTranscriptExporter.timestampText(seconds)
            let path = "screenshots/\(image.filename)"
            let analysis = self.imageAnalyses[image.filename] ?? HTMLText.imageAnalysisMarker(image.filename)
            return (seconds, """
            <li><div class="line">\(time) <strong>Screenshot</strong></div>
            <figure><a href="\(path)"><img src="\(path)" alt="Screenshot at \(timeText)"></a></figure>
            \(analysis)</li>
            """)
        }
        let transcript = rows.sorted { $0.seconds < $1.seconds }.map(\.html).joined(separator: "\n")

        let emptyMessage = self.stoppedAt == nil ? "No live captions yet." : "No live captions were captured."
        let captionsStatus = captions.isEmpty ? "<p>\(emptyMessage)</p>" : ""
        let timeline = rows.isEmpty ? "" : "<ol role=\"list\">\(transcript)</ol>"
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'self' file:; base-uri 'none'">
          <title>\(title) · Meeting transcript</title>
          <style>
            :root { font-family: system-ui, sans-serif; background: white; color: #171b24; }
            body { max-width: 46rem; margin: 0 auto; padding: 2.5rem 1.25rem; line-height: 1.55; }
            h1 { margin: 0; font-size: clamp(1.8rem, 5vw, 2.75rem); line-height: 1.15; overflow-wrap: anywhere; }
            h2 { margin-top: 2rem; font-size: 1.15rem; }
            header p, .note, time, .partial { color: #505a6a; }
            ol { list-style: none; margin: 1rem 0 0; padding: 0; }
            li { margin-bottom: 1.25rem; padding-inline-start: .75rem; border-inline-start: 2px solid #c8d2e1; }
            li p { margin: .3rem 0 0; white-space: pre-wrap; overflow-wrap: anywhere; }
            figure { margin: .5rem 0 0; }
            figure img { display: block; max-width: 100%; height: auto; border: 1px solid #c8d2e1; border-radius: .25rem; }
            .line { font-size: .9rem; }
            .line time { margin-inline-end: .35rem; font-variant-numeric: tabular-nums; }
            .partial { font-style: italic; }
            \(HTMLText.annotationStyles)
            @media print { body { max-width: none; padding: 0; } li { break-inside: avoid; } }
          </style>
        </head>
        <body>
          <header><h1>\(title)</h1><p>Started \(started)<br>\(status)</p></header>
          <main>
            <h2>Live transcript</h2>
            <p class="note">FluidMeet generates the full transcript separately after recording.</p>
            \(note)
            \(captionsStatus)
            \(timeline)
          </main>
        </body>
        </html>
        """
        try html.write(to: self.url, atomically: true, encoding: .utf8)
    }

    private static func dateElement(_ date: Date) -> String {
        "<time datetime=\"\(date.formatted(.iso8601))\">\(HTMLText.escape(date.formatted(date: .abbreviated, time: .standard)))</time>"
    }

    private static func elapsedTimeElement(_ seconds: TimeInterval) -> String {
        let time = MeetingTranscriptExporter.timestampText(seconds)
        return "<time datetime=\"PT\(seconds.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...3)).grouping(.never)))S\">\(time)</time>"
    }
}
