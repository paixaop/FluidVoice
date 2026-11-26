import Foundation

actor CaptureLogWriter {
    enum Entry {
        case transcript(String)
        case screenshot(Data)
    }

    nonisolated struct EntryLocation {
        let page: URL
        let id: String
    }

    nonisolated static let folderName = "FluidVoice Capture Log"
    nonisolated static let pageName = "index.html"

    private let folder: URL
    private var activePageFile: URL {
        self.folder.appendingPathComponent("active-transcript")
    }

    init(
        folder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent(CaptureLogWriter.folderName, isDirectory: true)
    ) {
        self.folder = folder
    }

    func preparePage() throws -> URL {
        try self.withPageLock {
            let pageURL = try self.activePage()
            if !FileManager.default.fileExists(atPath: pageURL.path) {
                try Self.emptyPage.write(to: pageURL, atomically: true, encoding: .utf8)
            }
            return pageURL
        }
    }

    func startNewTranscript(at startedAt: Date = .now) throws -> URL {
        try self.withPageLock {
            let date = startedAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let name = "transcript-\(date)-\(UUID().uuidString.lowercased()).html"
            let page = self.folder.appendingPathComponent(name)
            try Self.emptyPage.write(to: page, atomically: true, encoding: .utf8)
            do {
                try name.write(to: self.activePageFile, atomically: true, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: page)
                throw error
            }
            return page
        }
    }

    @discardableResult
    func append(_ entry: Entry, at timestamp: Date) throws -> EntryLocation {
        try self.withPageLock {
            let pageURL = try self.activePage()
            let existing = if FileManager.default.fileExists(atPath: pageURL.path) {
                try String(contentsOf: pageURL, encoding: .utf8)
            } else {
                Self.emptyPage
            }
            guard existing.hasPrefix(Self.documentMarker), existing.hasSuffix("</html>"),
                  let latest = existing.range(of: "<div id=\"latest\"></div>"),
                  let entriesEnd = existing.range(of: "</ol>", options: .backwards, range: existing.startIndex..<latest.lowerBound)
            else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The capture log HTML has changed. Move it out of the log folder to start a new page."])
            }

            let id = UUID().uuidString.lowercased()
            let title: String
            let content: String
            var imageURL: URL?
            switch entry {
            case let .transcript(text):
                title = "Dictation"
                content = "<p class=\"transcript\">\(HTMLText.escape(text))</p>"
            case let .screenshot(png):
                title = "Screenshot"
                let images = self.folder.appendingPathComponent("images", isDirectory: true)
                try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
                let filename = "\(id).png"
                let fileURL = images.appendingPathComponent(filename)
                try png.write(to: fileURL, options: .atomic)
                imageURL = fileURL
                let path = "images/\(filename)"
                content = "<a href=\"\(path)\"><img src=\"\(path)\" alt=\"Open screenshot at full size\" loading=\"lazy\"></a>\(HTMLText.imageAnalysisMarker(id))"
            }

            let isoDate = timestamp.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            let label = HTMLText.escape(timestamp.formatted(date: .abbreviated, time: .standard))
            let item = """

                 <li><article id="entry-\(id)">
                   <h2>\(title)</h2>
                   <time datetime="\(isoDate)">\(label)</time>
                   \(content)
                 </article></li>
            """
            var body = String(existing[..<entriesEnd.lowerBound])
            if body.hasSuffix(Self.emptyEntry) { body.removeLast(Self.emptyEntry.count) }
            let updated = body + item + existing[entriesEnd.lowerBound...]
            do {
                try updated.write(to: pageURL, atomically: true, encoding: .utf8)
            } catch {
                if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
                throw error
            }
            return EntryLocation(page: pageURL, id: id)
        }
    }

    func addImageAnalysis(_ markdown: String, to entry: EntryLocation) throws {
        try self.withPageLock {
            guard entry.page.deletingLastPathComponent().standardizedFileURL.path == self.folder.standardizedFileURL.path,
                  FileManager.default.fileExists(atPath: entry.page.path)
            else { return }
            try HTMLText.writeImageAnalysis(markdown, id: entry.id, to: entry.page)
        }
    }

    func savedTranscripts() throws -> [HTMLText.Transcript] {
        guard FileManager.default.fileExists(atPath: self.folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: self.folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { page in
            let name = page.lastPathComponent
            guard name == Self.pageName || (name.hasPrefix("transcript-") && page.pathExtension == "html") else { return nil }
            return HTMLText.describeTranscript(page)
        }
    }

    private func activePage() throws -> URL {
        guard FileManager.default.fileExists(atPath: self.activePageFile.path) else {
            return self.folder.appendingPathComponent(Self.pageName)
        }
        let name = try String(contentsOf: self.activePageFile, encoding: .utf8)
        guard name.hasPrefix("transcript-"), name.hasSuffix(".html"), name.utf8.count <= 128,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { throw CocoaError(.fileReadCorruptFile) }
        return self.folder.appendingPathComponent(name)
    }

    /// Keep each read–modify–write together when two FluidVoice processes use the same log.
    private func withPageLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try HTMLText.withTranscriptLock(in: self.folder, operation)
    }

    nonisolated static let documentMarker = "<!doctype html>\n<!-- FluidVoice Capture Log -->"

    private static let pageStart = documentMarker + "\n" + """
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
      <title>FluidVoice Capture Log</title>
      <style>
        :root { font-family: system-ui, sans-serif; background: white; color: #171b24; }
        body { max-width: 55rem; margin: 0 auto; padding: 2.5rem 1.25rem; line-height: 1.55; }
        h1 { margin: 0; font-size: clamp(1.8rem, 5vw, 3rem); line-height: 1.15; letter-spacing: -.035em; }
        header a { display: inline-block; margin-top: .55rem; }
        a { color: #254c8c; text-underline-offset: .18em; }
        a:focus-visible { outline: 2px solid #254c8c; outline-offset: 4px; }
        ol { list-style: none; padding: 0 0 0 1.15rem; margin: 2rem 0 0; border-inline-start: 1px solid #c8d2e1; }
        li { position: relative; margin-bottom: 1.9rem; }
        li:not(.empty)::before { content: ""; position: absolute; left: -1.4rem; top: .52rem; width: .45rem; height: .45rem; border-radius: 50%; background: #254c8c; }
        h2 { display: inline; margin: 0 .6rem 0 0; font-size: 1rem; }
        time, .empty { color: #505a6a; font-size: .9rem; }
        .transcript { max-width: 68ch; margin: .45rem 0 0; white-space: pre-wrap; overflow-wrap: anywhere; }
        article img { display: block; max-width: 100%; height: auto; margin-top: .65rem; border: 1px solid #d7dce4; box-sizing: border-box; }
        \(HTMLText.annotationStyles)
        @media print { body { max-width: none; padding: 0; } header a { display: none; } article img { break-inside: avoid; } }
      </style>
    </head>
    <body>
      <header><h1>FluidVoice Capture Log</h1><a href="#latest">End of log</a></header>
      <main>
        <ol role="list" aria-label="Captures">
    """

    private static let emptyEntry = "<li class=\"empty\">Screenshots and dictation will appear here as you capture them.</li>"
    private static let emptyPage = pageStart + emptyEntry + pageEnd

    private static let pageEnd = """
    </ol>
        <div id="latest"></div>
      </main>
    </body>
    </html>
    """
}
