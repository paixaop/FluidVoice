import AppKit
import Combine

@MainActor
final class CaptureLog: ObservableObject {
    static let shared = CaptureLog()

    @Published private(set) var errorMessage: String?
    private let writer = CaptureLogWriter()
    private var pendingOperation: Task<Void, Never>?

    private init() {}

    func record(_ entry: CaptureLogWriter.Entry, at timestamp: Date = .now) {
        guard SettingsStore.shared.captureLogEnabled else { return }
        self.enqueue {
            try await self.writer.append(entry, at: timestamp)
        }
    }

    func openPage() {
        self.enqueue {
            let page = try await self.writer.preparePage()
            guard NSWorkspace.shared.open(page) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The capture log couldn’t be opened in your browser."])
            }
        }
    }

    func finishPendingWrites() async {
        await self.pendingOperation?.value
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = self.pendingOperation
        self.pendingOperation = Task {
            await previous?.value
            do {
                try await operation()
                if self.errorMessage != nil { self.errorMessage = nil }
            } catch {
                self.errorMessage = error.localizedDescription
                DebugLogger.shared.error("Capture log update failed: \(error.localizedDescription)", source: "CaptureLog")
            }
        }
    }
}
