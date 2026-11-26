@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class CaptureLogWriterTests: XCTestCase {
    func testLogAppendsEscapedDictationAndRelativeImageLinksAcrossWriters() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = CaptureLogWriter(folder: folder)
        let page = try await writer.preparePage()
        XCTAssertTrue(try String(contentsOf: page, encoding: .utf8).contains("Screenshots and dictation will appear here"))

        let originalText = "<script>alert('test')</script> & notes\nSecond line"
        let firstTimestamp = Date(timeIntervalSince1970: 0)
        try await writer.append(.transcript(originalText), at: firstTimestamp)

        let reopened = CaptureLogWriter(folder: folder)
        let png = Data([137, 80, 78, 71])
        try await reopened.append(.screenshot(png), at: firstTimestamp.addingTimeInterval(2))
        try await reopened.append(.transcript("Third entry"), at: firstTimestamp.addingTimeInterval(3))

        let imageFolder = folder.appendingPathComponent("images")
        let images = try FileManager.default.contentsOfDirectory(atPath: imageFolder.path)
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(try Data(contentsOf: imageFolder.appendingPathComponent(image)), png)

        let html = try String(contentsOf: page, encoding: .utf8)
        let first = try XCTUnwrap(html.range(of: "&lt;script&gt;alert('test')&lt;/script&gt; &amp; notes\nSecond line"))
        let second = try XCTUnwrap(html.range(of: "<img src=\"images/\(image)\""))
        let third = try XCTUnwrap(html.range(of: "Third entry"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertLessThan(second.lowerBound, third.lowerBound)
        XCTAssertTrue(html.contains("datetime=\"1970-01-01T00:00:00.000Z\""))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("Screenshots and dictation will appear here"))
        XCTAssertTrue(html.hasSuffix("</html>"))
    }

    func testConcurrentWritersKeepEveryEntry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writers = [CaptureLogWriter(folder: folder), CaptureLogWriter(folder: folder)]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                let writer = writers[index % writers.count]
                group.addTask {
                    _ = try await writer.append(.transcript("Entry [\(index)]"), at: .now)
                }
            }
            try await group.waitForAll()
        }

        let page = try await writers[0].preparePage()
        let html = try String(contentsOf: page, encoding: .utf8)
        for index in 0..<12 {
            XCTAssertEqual(html.components(separatedBy: "Entry [\(index)]").count, 2)
        }
    }

    func testNewTranscriptPreservesOldLogAndKeepsDelayedAnalysisWithItsScreenshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstWriter = CaptureLogWriter(folder: folder)
        let old = try await firstWriter.preparePage()
        try await firstWriter.append(.transcript("Original voice text"), at: .now)
        let screenshot = try await firstWriter.append(.screenshot(Data([137, 80, 78, 71])), at: .now)

        let secondWriter = CaptureLogWriter(folder: folder)
        let current = try await secondWriter.startNewTranscript()
        let reopened = try await firstWriter.preparePage()
        XCTAssertEqual(reopened, current)
        XCTAssertNotEqual(old, current)
        try await firstWriter.append(.transcript("New voice text"), at: .now)
        try await secondWriter.addImageAnalysis("**Visible item** & details", to: screenshot)
        let saved = try await secondWriter.savedTranscripts()
        XCTAssertEqual(Set(saved.map { $0.url.lastPathComponent }), [old.lastPathComponent, current.lastPathComponent])
        let oldHTML = try String(contentsOf: old, encoding: .utf8)
        let currentHTML = try String(contentsOf: current, encoding: .utf8)
        XCTAssertTrue(oldHTML.contains("<summary>Image analysis</summary>"))
        XCTAssertTrue(oldHTML.contains("<strong>Visible item</strong> &amp; details"))
        XCTAssertTrue(oldHTML.contains("Original voice text"))
        XCTAssertFalse(oldHTML.contains("New voice text"))
        XCTAssertTrue(currentHTML.contains("New voice text"))
        XCTAssertFalse(currentHTML.contains("<summary>Image analysis</summary>"))
    }

    func testSummaryInputExcludesPreviousSummaryAndKeepsCapturesAndAnalysis() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = CaptureLogWriter(folder: folder)
        let page = try await writer.preparePage()
        let screenshot = try await writer.append(.screenshot(Data([137, 80, 78, 71])), at: .now)
        try await writer.addImageAnalysis("Screenshot findings", to: screenshot)
        try HTMLText.writeSummary("Previous model summary", to: page)
        try await writer.append(.transcript("New dictation after summary"), at: .now)

        let input = try HTMLText.summaryInput(for: page)
        XCTAssertTrue(input.body.contains("New dictation after summary"))
        XCTAssertTrue(input.body.contains("Screenshot findings"))
        XCTAssertFalse(input.body.contains("Previous model summary"))
        XCTAssertEqual(input.images.count, 1)
        try HTMLText.writeSummary("Replacement summary", to: page)
        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains("Replacement summary"))
        XCTAssertFalse(html.contains("Previous model summary"))
        XCTAssertTrue(html.contains("New dictation after summary"))
        XCTAssertFalse(try HTMLText.summaryInput(for: page).body.contains("Replacement summary"))
    }

    func testAppendPreservesAnUnrecognizedPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer = CaptureLogWriter(folder: folder)
        let page = try await writer.preparePage()
        try "Edited by hand".write(to: page, atomically: true, encoding: .utf8)

        do {
            try await writer.append(.screenshot(Data([137, 80, 78, 71])), at: .now)
            XCTFail("An unrecognized page should never be overwritten")
        } catch {
            XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "Edited by hand")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("images").path))
        }
    }
}
