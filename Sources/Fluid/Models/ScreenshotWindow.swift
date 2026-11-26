import CoreGraphics
import Foundation

enum ScreenshotMode: String, CaseIterable {
    case fullScreen
    case window
    case scrollingWindow

    var needsWindow: Bool {
        self != .fullScreen
    }

    var title: String {
        switch self {
        case .fullScreen: "Full Screen (Main Display)"
        case .window: "Selected Window"
        case .scrollingWindow: "Scrolling Window / Web Page"
        }
    }
}

nonisolated struct ScreenshotWindow: Codable, Equatable, Identifiable {
    let id: CGWindowID
    let processID: pid_t
    let launchDate: Date
    let bundleIdentifier: String
    let applicationName: String
    let title: String?

    var label: String {
        "\(self.applicationName) — \(self.title ?? "Untitled Window")"
    }

    func isSameLiveWindow(as other: Self) -> Bool {
        self.id == other.id && self.processID == other.processID && self.launchDate == other.launchDate
            && self.bundleIdentifier == other.bundleIdentifier
    }

    func matchingWindow(in windows: [Self], originalProcessIsRunning: Bool) -> Self? {
        if originalProcessIsRunning {
            return windows.first { self.isSameLiveWindow(as: $0) }
        }

        // Window IDs change when an app restarts. Only rebind to an unambiguous title.
        guard let title = self.title else { return nil }
        let matches = windows.filter { $0.bundleIdentifier == self.bundleIdentifier && $0.title == title }
        return matches.count == 1 ? matches.first : nil
    }
}
