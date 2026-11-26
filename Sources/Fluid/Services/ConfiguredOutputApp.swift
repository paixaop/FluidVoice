import AppKit
import ApplicationServices

struct ConfiguredOutputApp: Codable, Equatable {
    let bundleIdentifier: String
    let name: String

    init?(applicationURL: URL) {
        guard applicationURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: applicationURL),
              let identifier = bundle.bundleIdentifier,
              !identifier.isEmpty, identifier != Bundle.main.bundleIdentifier
        else { return nil }

        self.bundleIdentifier = identifier
        self.name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }

    func deliverTranscript(
        _ text: String,
        keepClipboardBackup: Bool,
        isOutputValid: @escaping @MainActor () -> Bool
    ) async -> TextDeliveryResult {
        guard !text.isEmpty else { return .recoverableFailure(.emptyText) }
        let isDeliveryValid = { @MainActor in self.isSelected && isOutputValid() }
        return await PasteDeliveryCoordinator.shared.deliver(
            text,
            preserveTranscriptOnClipboard: keepClipboardBackup,
            isOutputValid: isDeliveryValid,
            prepareTarget: { await self.prepareTarget(isOutputValid: isDeliveryValid) }
        )
    }

    func deliverScreenshot(_ png: Data, fileURL: URL) async -> TextDeliveryResult {
        await PasteDeliveryCoordinator.shared.deliverScreenshot(png, fileURL: fileURL, isOutputValid: { self.isSelected }) {
            await self.prepareTarget(isOutputValid: { self.isSelected })
        }
    }

    private var isSelected: Bool {
        !Task.isCancelled && SettingsStore.shared.activeOutputApp == self && !GlobalHotkeyManager.currentSessionIsLocked()
    }

    private func prepareTarget(isOutputValid: () -> Bool) async -> PasteDeliveryCoordinator.Target? {
        guard isOutputValid(), AXIsProcessTrusted(),
              await TypingService.waitForHotkeyModifiersReleased(timeout: 5), isOutputValid()
        else { return nil }

        let workspace = NSWorkspace.shared
        let app: NSRunningApplication
        if let frontmost = workspace.frontmostApplication, frontmost.bundleIdentifier == self.bundleIdentifier {
            app = frontmost
        } else {
            guard let url = workspace.urlForApplication(withBundleIdentifier: self.bundleIdentifier) else { return nil }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.addsToRecentItems = false
            guard let opened = try? await workspace.openApplication(at: url, configuration: configuration),
                  opened.bundleIdentifier == self.bundleIdentifier, isOutputValid()
            else { return nil }
            app = opened
        }

        let pid = app.processIdentifier
        let deadline = ContinuousClock.now + .seconds(2)
        var wasFrontmost = false
        while ContinuousClock.now < deadline, isOutputValid(), !app.isTerminated {
            if workspace.frontmostApplication?.processIdentifier == pid {
                wasFrontmost = true
                if let focus = TypingService.captureSystemFocusTarget(), focus.pid == pid,
                   !focus.isSecureTextField, !DeliveryTargetAssessment.assessFocusedElement().isCertainlyNotEditable
                {
                    return .init(pid: pid, isStillFocused: {
                        !app.isTerminated && workspace.frontmostApplication?.processIdentifier == pid &&
                            TypingService.isExactFocusTargetActive(focus) && !focus.isSecureTextField
                    })
                }
            } else if wasFrontmost {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return nil
    }
}
