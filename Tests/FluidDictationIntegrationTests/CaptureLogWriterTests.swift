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
                    try await writer.append(.transcript("Entry [\(index)]"), at: .now)
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
