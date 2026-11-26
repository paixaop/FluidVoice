import Darwin
import Foundation

nonisolated enum HTMLText {
    struct Transcript {
        let url: URL
        let title: String
        let date: Date
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func imageAnalysisMarker(_ id: String) -> String {
        "<!-- image-analysis:\(id) -->"
    }

    static func imageAnalysis(_ markdown: String) -> String {
        "<details class=\"image-analysis\" open><summary>Image analysis</summary>\(self.markdownBlocks(markdown))</details>"
    }

    private static func markdownBlocks(_ markdown: String) -> String {
        CommandMarkdownParser.parse(markdown).map { block in
            switch block.content {
            case let .paragraph(text): return "<p>\(Self.inline(text))</p>"
            case let .heading(text, _): return "<p><strong>\(Self.inline(text))</strong></p>"
            case let .listItem(text, marker, depth):
                return "<p style=\"margin-inline-start: \(depth)em\">\(Self.escape(marker)) \(Self.inline(text))</p>"
            case let .quote(text): return "<blockquote>\(Self.inline(text))</blockquote>"
            case let .code(code, _): return "<pre><code>\(Self.escape(code))</code></pre>"
            case let .table(headers, rows):
                let headings = headers.map { "<th scope=\"col\">\(Self.inline($0))</th>" }.joined()
                let body = rows.map { row in
                    "<tr>" + row.map { "<td>\(Self.inline($0))</td>" }.joined() + "</tr>"
                }.joined()
                return "<div class=\"analysis-table\"><table><thead><tr>\(headings)</tr></thead><tbody>\(body)</tbody></table></div>"
            case .divider: return "<hr>"
            }
        }.joined(separator: "\n")
    }

    static func writeImageAnalysis(_ markdown: String, id: String, to page: URL) throws {
        let html = try String(contentsOf: page, encoding: .utf8)
        guard let marker = html.range(of: Self.imageAnalysisMarker(id)) else { return }
        let updated = Self.ensureAnnotationStyles(html.replacingCharacters(in: marker, with: Self.imageAnalysis(markdown)))
        try updated.write(to: page, atomically: true, encoding: .utf8)
    }

    private static let summaryStart = "<!-- transcript-summary-start -->"
    private static let summaryEnd = "<!-- transcript-summary-end -->"

    static func describeTranscript(_ url: URL) -> Transcript? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let file = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 16_384),
              let headerEnd = data.range(of: Data("</header>".utf8)),
              let header = String(bytes: data[..<headerEnd.upperBound], encoding: .utf8)
        else { return nil }
        guard Self.isCompletedTranscript(header),
              let open = header.range(of: "<title>"),
              let close = header.range(of: "</title>", range: open.upperBound..<header.endIndex)
        else { return nil }
        let title = String(header[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return Transcript(url: url, title: title, date: values.contentModificationDate ?? .distantPast)
    }

    static func summaryInput(for page: URL) throws -> (body: String, images: [URL]) {
        let html = try Self.readCompletedTranscript(page)
        let source = try Self.withoutSummary(html)
        guard let start = source.range(of: "<body>"),
              let end = source.range(of: "</body>", options: .backwards),
              start.upperBound <= end.lowerBound
        else { throw CocoaError(.fileReadCorruptFile) }
        let body = String(source[start.upperBound..<end.lowerBound])
        let directory = page.deletingLastPathComponent()
        let images = body.matches(of: #/<img src="((?:images|screenshots)/[0-9a-fA-F-]{36}\.png)"/#).compactMap { match -> URL? in
            let image = directory.appendingPathComponent(String(match.1))
            guard let values = try? image.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { return nil }
            return image
        }
        return (body, images)
    }

    static func writeSummary(_ markdown: String, to page: URL) throws {
        try self.withTranscriptLock(in: page.deletingLastPathComponent()) {
            var html = try Self.withoutSummary(Self.readCompletedTranscript(page))
            guard let end = html.range(of: "</main>", options: .backwards) else { throw CocoaError(.fileReadCorruptFile) }
            let summary = """
            \(Self.summaryStart)
            <section class="transcript-summary"><h2>Transcript summary</h2>
            \(Self.markdownBlocks(markdown))
            </section>
            \(Self.summaryEnd)

            """
            html.insert(contentsOf: summary, at: end.lowerBound)
            try Self.ensureAnnotationStyles(html).write(to: page, atomically: true, encoding: .utf8)
        }
    }

    private static func readCompletedTranscript(_ page: URL) throws -> String {
        let html = try String(contentsOf: page, encoding: .utf8)
        guard Self.isCompletedTranscript(html) else { throw CocoaError(.fileReadCorruptFile) }
        return html
    }

    private static func isCompletedTranscript(_ html: String) -> Bool {
        html.hasPrefix(CaptureLogWriter.documentMarker) ||
            (html.contains("· Meeting transcript</title>") && html.contains("<br>Stopped <time "))
    }

    private static func withoutSummary(_ html: String) throws -> String {
        var source = html
        while let start = source.range(of: Self.summaryStart) {
            guard let end = source.range(of: Self.summaryEnd + "\n", range: start.upperBound..<source.endIndex) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            source.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return source
    }

    static func withTranscriptLock<T>(in directory: URL, _ operation: () throws -> T) throws -> T {
        let url = directory.appendingPathComponent(".lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try operation()
    }

    private static func ensureAnnotationStyles(_ html: String) -> String {
        guard !html.contains(self.annotationStyles), let end = html.range(of: "</style>") else { return html }
        var styled = html
        styled.insert(contentsOf: Self.annotationStyles + "\n", at: end.lowerBound)
        return styled
    }

    static let annotationStyles = """
    :is(.image-analysis, .transcript-summary) { margin-top: .75rem; padding: .5rem .75rem; border-inline-start: 3px solid #b2c3dc; background: #f2f6fb; }
    .image-analysis summary { font-size: .9rem; font-weight: 650; cursor: pointer; }
    :is(.image-analysis, .transcript-summary) p, :is(.image-analysis, .transcript-summary) pre { margin: .35rem 0; white-space: pre-wrap; overflow-wrap: anywhere; }
    .analysis-table { overflow-x: auto; }
    .analysis-table table { border-collapse: collapse; }
    .analysis-table th, .analysis-table td { padding: .25rem .5rem; border: 1px solid #c8d2e1; text-align: start; }
    """

    private static func inline(_ text: AttributedString) -> String {
        text.runs.map { run in
            var html = Self.escape(String(text[run.range].characters))
            if run.inlinePresentationIntent?.contains(.code) == true { html = "<code>\(html)</code>" }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { html = "<em>\(html)</em>" }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { html = "<strong>\(html)</strong>" }
            return html
        }.joined()
    }
}
