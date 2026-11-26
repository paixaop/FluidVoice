import AppKit
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotCapture {
    static let shared = ScreenshotCapture()

    private var isCapturing = false

    private init() {}

    private nonisolated enum CaptureError: LocalizedError {
        case permissionRequired
        case displayUnavailable
        case windowUnavailable
        case imageUnavailable
        case imageEncodingFailed

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                "Allow FluidVoice under Privacy & Security → Screen & System Audio Recording, then try again."
            case .displayUnavailable:
                "The main display is unavailable."
            case .windowUnavailable:
                "Open the selected window or choose a window in Settings → Capture."
            case .imageUnavailable:
                "ScreenCaptureKit didn’t return an image."
            case .imageEncodingFailed:
                "The screenshot could not be saved as a PNG."
            }
        }
    }

    nonisolated static let folderName = "FluidVoice Screenshots"

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showFolder() throws {
        let folder = try self.screenshotFolder()
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    static func availableWindows() async throws -> [ScreenshotWindow] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return self.windowChoices(in: content).map(\.choice).sorted {
            let order = $0.label.localizedStandardCompare($1.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func captureFromShortcut(meeting: MeetingSessionCoordinator?) async {
        guard !self.isCapturing else { return }
        self.isCapturing = true
        defer { self.isCapturing = false }

        let settings = SettingsStore.shared
        let mode = settings.screenshotMode
        let savedWindow = settings.screenshotWindow
        let outputApp = settings.activeOutputApp
        let meetingID = meeting?.screenshotSessionID
        do {
            guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionRequired }
            let capturesWindow = mode.needsWindow
            let content = try await SCShareableContent.excludingDesktopWindows(capturesWindow, onScreenWindowsOnly: !capturesWindow)
            let filter: SCContentFilter
            var capturedWindow: ScreenshotWindow?
            var scrollWindow: SCWindow?
            switch mode {
            case .fullScreen:
                let mainDisplayID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
                    throw CaptureError.displayUnavailable
                }
                let overlayID = CaptureAI.shared.panelWindowID
                filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowID == overlayID })
            case .window, .scrollingWindow:
                guard let savedWindow else { throw CaptureError.windowUnavailable }
                let originalApp = NSRunningApplication(processIdentifier: savedWindow.processID)
                let originalProcessIsRunning = originalApp?.bundleIdentifier == savedWindow.bundleIdentifier
                    && originalApp?.launchDate == savedWindow.launchDate
                let windows = Self.windowChoices(in: content)
                guard let match = savedWindow.matchingWindow(in: windows.map(\.choice), originalProcessIsRunning: originalProcessIsRunning),
                      let window = windows.first(where: { $0.choice.id == match.id })?.window, window.isOnScreen
                else { throw CaptureError.windowUnavailable }
                capturedWindow = match
                filter = SCContentFilter(desktopIndependentWindow: window)
                if mode == .scrollingWindow { scrollWindow = window }
            }

            let frame: (image: CGImage, hostTime: CMTime, capturedAt: Date)
            let conversationAtCaptureStart: String?
            if let scrollWindow {
                let time = CMClockGetTime(CMClockGetHostTimeClock())
                let date = Date.now
                conversationAtCaptureStart = meeting?.screenshotConversation(at: time)
                frame = try (await ScrollingScreenshot.capture(window: scrollWindow, filter: filter), time, date)
            } else {
                conversationAtCaptureStart = nil
                frame = try await Self.captureFrame(for: filter)
            }
            let encoding = Task { try await Self.encodePNG(frame.image) }
            let logEntry = CaptureLog.shared.recordScreenshot(encoding, at: frame.capturedAt)
            var addedToMeeting = false
            if let meetingID {
                addedToMeeting = meeting?.recordScreenshot(
                    for: meetingID,
                    capturedAt: frame.hostTime,
                    png: encoding,
                    conversationAtCaptureStart: conversationAtCaptureStart,
                    captureLogEntry: logEntry
                ) ?? false
            }
            let png = try await encoding.value
            let url = try await Self.savePNG(png, capturedAt: frame.capturedAt)
            if !addedToMeeting {
                CaptureAI.shared.analyzeScreenshot(at: url, meetingID: nil, conversation: "") { result in
                    await CaptureLog.shared.addImageAnalysis(result, to: logEntry)
                }
            }

            if let capturedWindow, capturedWindow != savedWindow,
               settings.screenshotMode.needsWindow, settings.screenshotWindow == savedWindow
            {
                settings.screenshotWindow = capturedWindow
            }

            if let outputApp,
               case .recoverableFailure = await outputApp.deliverScreenshot(png, fileURL: url)
            {
                self.showPasteFailure(appName: outputApp.name, fileURL: url)
            }
        } catch {
            self.showFailure(error)
        }
    }

    nonisolated static func captureImage(for filter: SCContentFilter) async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: self.configuration(for: filter))
    }

    private nonisolated static func captureFrame(for filter: SCContentFilter) async throws -> (image: CGImage, hostTime: CMTime, capturedAt: Date) {
        let configuration = self.configuration(for: filter)
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                guard let image else {
                    continuation.resume(throwing: error ?? CaptureError.imageUnavailable)
                    return
                }
                let time = CMClockGetTime(CMClockGetHostTimeClock())
                continuation.resume(returning: (image, time, .now))
            }
        }
    }

    private nonisolated static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private static func windowChoices(in content: SCShareableContent) -> [(window: SCWindow, choice: ScreenshotWindow)] {
        content.windows.compactMap { window in
            guard window.windowLayer == 0, !window.frame.isEmpty,
                  let owner = window.owningApplication, !owner.bundleIdentifier.isEmpty,
                  let launchDate = NSRunningApplication(processIdentifier: owner.processID)?.launchDate
            else { return nil }

            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let choice = ScreenshotWindow(
                id: window.windowID,
                processID: owner.processID,
                launchDate: launchDate,
                bundleIdentifier: owner.bundleIdentifier,
                applicationName: owner.applicationName,
                title: title?.isEmpty == false ? title : nil
            )
            return (window, choice)
        }
    }

    private nonisolated static func screenshotFolder() throws -> URL {
        let manager = FileManager.default
        let pictures = try manager.url(for: .picturesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = pictures.appendingPathComponent(self.folderName, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @concurrent
    private static func encodePNG(_ image: CGImage) async throws -> Data {
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.imageEncodingFailed }
        return png as Data
    }

    @concurrent
    private static func savePNG(_ png: Data, capturedAt: Date) async throws -> URL {
        let timestamp = capturedAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let filename = "Screenshot \(timestamp) \(UUID().uuidString.prefix(8)).png"
        let url = try self.screenshotFolder().appendingPathComponent(filename)
        try png.write(to: url, options: .atomic)
        return url
    }

    private func showPasteFailure(appName: String, fileURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Screenshot Saved"
        alert.informativeText = "FluidVoice couldn’t paste into \(appName). Focus a field that accepts images and try again, or use the saved PNG."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Screenshot Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        let needsPermission = error as? CaptureError == .permissionRequired
        if needsPermission { alert.addButton(withTitle: "Open System Settings") }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, needsPermission {
            Self.openScreenRecordingSettings()
        }
    }
}
