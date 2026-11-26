import CoreGraphics
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class ScrollingScreenshotTests: XCTestCase {
    func testPromptFilesKeepUserEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imagePrompt = try CapturePrompt.image.file(in: directory)
        let summaryPrompt = try CapturePrompt.summary.file(in: directory)
        XCTAssertEqual(imagePrompt.lastPathComponent, "image_prompt.md")
        XCTAssertEqual(summaryPrompt.lastPathComponent, "summary-prompt.md")
        XCTAssertFalse(try String(contentsOf: summaryPrompt, encoding: .utf8).isEmpty)
        try "Check the axes and units.".write(to: imagePrompt, atomically: true, encoding: .utf8)
        XCTAssertEqual(try CapturePrompt.image.file(in: directory), imagePrompt)
        XCTAssertEqual(try String(contentsOf: imagePrompt, encoding: .utf8), "Check the axes and units.")
    }

    func testAlignsAndStitchesNativeViewportTiles() async throws {
        let page = try self.makePage(width: 160, height: 480)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 300)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 180, width: 160, height: 300)))
        let down = await ScrollingScreenshot.displacement(from: first, to: second, direction: 1)
        let up = await ScrollingScreenshot.displacement(from: second, to: first, direction: -1)
        let unchanged = await ScrollingScreenshot.displacement(from: first, to: first, direction: 1)
        XCTAssertEqual(down, 180)
        XCTAssertEqual(up, 180)
        XCTAssertEqual(unchanged, 0)
        let result = try await ScrollingScreenshot.stitch([.init(image: first, offset: 0), .init(image: second, offset: 180)])
        XCTAssertEqual(result.height, 480)
        XCTAssertEqual(result.width, 160)
        let seam = try XCTUnwrap(result.cropping(to: CGRect(x: 0, y: 210, width: 160, height: 70)))
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 210, width: 160, height: 70)))
        XCTAssertEqual(self.grayPixels(seam), self.grayPixels(expected))
    }

    private func makePage(width: Int, height: Int) throws -> CGImage {
        var seed: UInt64 = 30
        let pixels = (0..<(width * height)).map { _ -> UInt8 in
            seed = seed &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: seed >> 32)
        }
        let data = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: data,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func grayPixels(_ image: CGImage) -> Data? {
        let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context?.data.map { Data(bytes: $0, count: image.width * image.height) }
    }
}
