import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@MainActor
enum ScrollingScreenshot {
    private nonisolated enum CaptureError: LocalizedError {
        case accessibility, focus, alignment, tooLong, restore

        var errorDescription: String? {
            switch self {
            case .accessibility: "Enable Accessibility for FluidVoice to capture a scrolling window."
            case .focus: "Bring the selected window to the front and hover over its scrollable area before using the shortcut."
            case .alignment: "The window changed too much to stitch. Pause moving content and try again."
            case .tooLong: "The scrollable page is too long for one screenshot."
            case .restore: "FluidVoice couldn’t restore the original scroll position."
            }
        }
    }

    static func capture(window: SCWindow, filter: SCContentFilter) async throws -> CGImage {
        guard AXIsProcessTrusted(), let owner = window.owningApplication else { throw CaptureError.accessibility }
        let app = AXUIElementCreateApplication(owner.processID)
        AXUIElementSetMessagingTimeout(app, 0.35)
        let mouse = CGEvent(source: nil)?.location
        let axWindow = self.window(in: app, frame: window.frame, title: window.title)
        let area = axWindow.flatMap { self.scrollArea(in: $0, around: mouse, windowFrame: window.frame) }
        let viewport = area.flatMap(self.frame)?.intersection(window.frame) ?? window.frame.insetBy(dx: 1, dy: 0)
        guard viewport.width >= 40, viewport.height >= 40 else { throw CaptureError.alignment }
        let region = viewport.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let scrollbar: AXUIElement? = area.flatMap { self.attribute($0, kAXVerticalScrollBarAttribute) }
        if let scrollbar, let original = self.scrollPosition(scrollbar), self.canSetPosition(scrollbar) {
            return try await self.captureWithScrollbar(scrollbar, original: original, filter: filter, region: region)
        }

        guard self.isFrontWindow(window.windowID, processID: owner.processID),
              let mouse, viewport.contains(mouse)
        else { throw CaptureError.focus }
        return try await self.captureWithWheel(
            target: WheelTarget(point: mouse, processID: owner.processID, windowID: window.windowID),
            filter: filter,
            region: region
        )
    }

    private static func captureWithScrollbar(
        _ scrollbar: AXUIElement, original: Double, filter: SCContentFilter, region: CGRect
    ) async throws -> CGImage {
        let outcome: Result<CGImage, Error>
        do { outcome = try .success(await self.scanScrollbar(scrollbar, filter: filter, region: region)) } catch { outcome = .failure(error) }
        guard self.setPosition(scrollbar, original) else { throw CaptureError.restore }
        return try outcome.get()
    }

    private static func scanScrollbar(_ scrollbar: AXUIElement, filter: SCContentFilter, region: CGRect) async throws -> CGImage {
        guard self.setPosition(scrollbar, 0) else { throw CaptureError.alignment }
        var current = try await self.frameAfterScroll(filter: filter, region: region)
        var tiles = [Tile(image: current, offset: 0)]
        var position = 0.0
        var step = 0.08
        while position < 0.99_999 {
            let nextPosition = min(1, position + step)
            guard self.setPosition(scrollbar, nextPosition) else { throw CaptureError.alignment }
            let next = try await self.frameAfterScroll(filter: filter, region: region)
            let shift = await self.displacement(from: current, to: next, direction: 1)
            if let shift, shift > 0 {
                try self.append(next, displacement: shift, to: &tiles)
                step *= shift < current.height / 4 ? 1.6 : 1
                current = next
                position = nextPosition
            } else if shift == 0 {
                position = nextPosition
            } else {
                guard step > 0.00_001 else { throw CaptureError.alignment }
                step /= 2
            }
        }
        return try await self.stitch(tiles)
    }

    private static func captureWithWheel(
        target: WheelTarget, filter: SCContentFilter, region: CGRect
    ) async throws -> CGImage {
        let original = try await self.grab(filter: filter, region: region)
        var current = original
        var offset = 0
        let pixelsPerPoint = Double(original.height) / region.height
        let step = max(8, Int(region.height * 0.46))
        let result: Result<CGImage, Error>
        do {
            for _ in 0..<100 {
                try self.wheel(step, target: target)
                let next = try await self.frameAfterScroll(filter: filter, region: region)
                guard let shift = await self.displacement(from: current, to: next, direction: -1) else {
                    offset -= Int(Double(step) * pixelsPerPoint)
                    throw CaptureError.alignment
                }
                offset -= shift
                current = next
                if shift == 0 { break }
                if abs(offset) > 28_000 { throw CaptureError.tooLong }
            }
            var tiles = [Tile(image: current, offset: 0)]
            while true {
                try self.wheel(-step, target: target)
                let next = try await self.frameAfterScroll(filter: filter, region: region)
                guard let shift = await self.displacement(from: current, to: next, direction: 1) else {
                    offset += Int(Double(step) * pixelsPerPoint)
                    throw CaptureError.alignment
                }
                offset += shift
                current = next
                if shift == 0 { break }
                try self.append(next, displacement: shift, to: &tiles)
            }
            result = try .success(await self.stitch(tiles))
        } catch {
            result = .failure(error)
        }

        for _ in 0..<100 {
            if await self.displacement(from: original, to: current, direction: 1) == 0 {
                return try result.get()
            }
            guard offset != 0 else { break }
            let amount = min(step, max(1, Int((Double(abs(offset)) / pixelsPerPoint).rounded())))
            let direction = offset > 0 ? -1 : 1
            try self.wheel(-direction * amount, target: target)
            let next = try await self.frameAfterScroll(filter: filter, region: region)
            guard let shift = await self.displacement(from: current, to: next, direction: direction), shift > 0 else { break }
            offset += shift * direction
            current = next
        }
        throw CaptureError.restore
    }

    private struct WheelTarget {
        let point: CGPoint
        let processID: pid_t
        let windowID: CGWindowID
    }

    private static func wheel(_ points: Int, target: WheelTarget) throws {
        guard self.isFrontWindow(target.windowID, processID: target.processID),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(points), wheel2: 0, wheel3: 0)
        else { throw CaptureError.focus }
        event.location = target.point
        event.postToPid(target.processID)
    }

    private static func frameAfterScroll(filter: SCContentFilter, region: CGRect) async throws -> CGImage {
        // Give the target's next layout and compositor pass time to settle.
        try await Task.sleep(for: .milliseconds(200))
        return try await self.grab(filter: filter, region: region)
    }

    private static func grab(filter: SCContentFilter, region: CGRect) async throws -> CGImage {
        let image = try await ScreenshotCapture.captureImage(for: filter)
        let scale = CGFloat(filter.pointPixelScale)
        let rect = region.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let viewport = image.cropping(to: rect) else { throw CaptureError.alignment }
        return viewport
    }

    nonisolated struct Tile { let image: CGImage; let offset: Int }

    private static func append(_ image: CGImage, displacement: Int, to tiles: inout [Tile]) throws {
        let offset = (tiles.last?.offset ?? 0) + displacement
        guard offset + image.height <= 30_000, (offset + image.height) * image.width <= 40_000_000, tiles.count < 120 else {
            throw CaptureError.tooLong
        }
        tiles.append(Tile(image: image, offset: offset))
    }

    @concurrent
    static func stitch(_ tiles: [Tile]) async throws -> CGImage {
        guard let last = tiles.last else { throw CaptureError.alignment }
        if tiles.count == 1 { return last.image }
        let height = last.offset + last.image.height
        let width = last.image.width
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw CaptureError.tooLong }
        for (index, tile) in tiles.enumerated() {
            let top = index == 0 ? 0 : (tiles[index - 1].offset + tile.image.height + tile.offset) / 2
            let bottom = index == tiles.count - 1 ? height : (tile.offset + tile.image.height + tiles[index + 1].offset) / 2
            let fragment = CGRect(x: 0, y: top - tile.offset, width: width, height: bottom - top)
            guard let image = tile.image.cropping(to: fragment) else { throw CaptureError.alignment }
            canvas.draw(image, in: CGRect(x: 0, y: height - bottom, width: width, height: bottom - top))
        }
        guard let screenshot = canvas.makeImage() else { throw CaptureError.alignment }
        return screenshot
    }

    @concurrent
    static func displacement(from first: CGImage, to second: CGImage, direction: Int) async -> Int? {
        guard first.width == second.width, first.height == second.height else { return nil }
        let base = direction > 0 ? first : second
        let shifted = direction > 0 ? second : first
        let width = 80
        let height = min(first.height, 960)
        let before = self.samples(base, width: width, height: height)
        let after = self.samples(shifted, width: width, height: height)
        guard !before.isEmpty, !after.isEmpty else { return nil }

        func score(_ offset: Int) -> Double {
            var difference = 0
            var count = 0
            let padding = max(3, (height - offset) / 8)
            let rowStep = max(1, (height - offset) / 55)
            for row in stride(from: padding, to: height - offset - padding, by: rowStep) {
                for col in stride(from: 4, to: width - 4, by: 2) {
                    difference += abs(Int(before[(row + offset) * width + col]) - Int(after[row * width + col]))
                    count += 1
                }
            }
            return Double(difference) / Double(max(1, count))
        }

        if score(0) < 0.5 { return 0 }
        let candidates = (1...max(1, height * 3 / 4)).map { (offset: $0, score: score($0)) }
        guard let best = candidates.min(by: { $0.score < $1.score }), best.score < 3.5,
              candidates.allSatisfy({ abs($0.offset - best.offset) < 4 || $0.score > best.score + 0.18 })
        else { return nil }
        return max(1, Int((Double(best.offset) * Double(first.height) / Double(height)).rounded()))
    }

    private nonisolated static func samples(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let pointer = context.data else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    private static func scrollPosition(_ scrollbar: AXUIElement) -> Double? {
        let value: NSNumber? = self.attribute(scrollbar, kAXValueAttribute)
        guard let number = value?.doubleValue, (0...1).contains(number) else { return nil }
        return number
    }

    private static func setPosition(_ scrollbar: AXUIElement, _ position: Double) -> Bool {
        AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute as CFString, NSNumber(value: position)) == .success
    }

    private static func canSetPosition(_ scrollbar: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(scrollbar, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func window(in app: AXUIElement, frame: CGRect, title: String?) -> AXUIElement? {
        let windows: [AXUIElement] = self.attribute(app, kAXWindowsAttribute) ?? []
        return windows.first {
            guard let candidate = self.frame($0),
                  abs(candidate.minX - frame.minX) + abs(candidate.minY - frame.minY) +
                  abs(candidate.width - frame.width) + abs(candidate.height - frame.height) < 10
            else { return false }
            let candidateTitle: String? = self.attribute($0, kAXTitleAttribute)
            return title == nil || candidateTitle == nil || title == candidateTitle
        }
    }

    private static func scrollArea(in root: AXUIElement, around point: CGPoint?, windowFrame: CGRect) -> AXUIElement? {
        var pending = [root]
        var best: (element: AXUIElement, area: CGFloat)?
        var hovered: (element: AXUIElement, area: CGFloat)?
        let deadline = ContinuousClock.now + .milliseconds(500)
        for _ in 0..<400 {
            guard ContinuousClock.now < deadline, let element = pending.popLast() else { break }
            let role: String? = self.attribute(element, kAXRoleAttribute)
            if role == kAXScrollAreaRole || role == "AXWebArea", let elementFrame = self.frame(element) {
                let visible = elementFrame.intersection(windowFrame)
                if visible.width >= 40, visible.height >= 40 {
                    let area = visible.width * visible.height
                    if best.map({ $0.area < area }) ?? true { best = (element, area) }
                    if point.map(visible.contains) == true, hovered.map({ $0.area > area }) ?? true { hovered = (element, area) }
                }
            }
            // Tables and web areas can expose thousands of document nodes.
            if role != "AXWebArea", role != kAXTableRole {
                let children: [AXUIElement] = self.attribute(element, kAXChildrenAttribute) ?? []
                pending.append(contentsOf: children.prefix(80).reversed())
            }
        }
        return hovered?.element ?? best?.element
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = self.attribute(element, kAXPositionAttribute),
              let size: AXValue = self.attribute(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func isFrontWindow(_ id: CGWindowID, processID: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let front = windows.first(where: {
                  ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) == processID
              })
        else { return false }
        return (front[kCGWindowNumber as String] as? CGWindowID) == id
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
