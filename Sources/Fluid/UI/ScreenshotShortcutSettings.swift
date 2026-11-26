import AppKit
import SwiftUI

struct ScreenshotShortcutSettings: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.theme) private var theme
    @StateObject private var permission = DictationScreenPermissionController()
    @State private var windows: [ScreenshotWindow] = []
    @State private var isLoadingWindows = false
    @State private var refreshRequest = 0
    @State private var windowError: String?
    @State private var folderError: String?

    private var windowRefreshID: Int? {
        self.settings.screenshotMode == .window && self.permission.isAllowed ? self.refreshRequest : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FluidDropdownPicker("Screenshot target", selectedTitle: self.settings.screenshotMode.title, selection: self.$settings.screenshotMode) {
                    ForEach(ScreenshotMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .fluidDropdownStyle()

                Button("Show in Finder") {
                    do {
                        try ScreenshotCapture.showFolder()
                        self.folderError = nil
                    } catch {
                        self.folderError = error.localizedDescription
                    }
                }
                .fluidOutlinedButton()
            }

            if self.permission.isAllowed, self.settings.screenshotMode == .window {
                self.windowControls
            } else if self.permission.hasChecked, !self.permission.isAllowed,
                      self.settings.screenshotHotkeyShortcut != nil || self.settings.screenshotMode == .window
            {
                self.permissionControls
            }

            if let error = self.folderError {
                Text(error).foregroundStyle(self.theme.palette.warning)
            }
        }
        .font(self.theme.typography.bodySmall)
        .task { await self.permission.refresh() }
        .task(id: self.windowRefreshID) { await self.refreshWindows() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await self.permission.refresh()
                self.refreshRequest += 1
            }
        }
    }

    private var permissionControls: some View {
        HStack(spacing: 10) {
            Button(self.permission.requiresSettings ? "Open System Settings" : "Allow Screen Access") {
                if self.permission.requiresSettings {
                    ScreenshotCapture.openScreenRecordingSettings()
                } else {
                    Task { await self.permission.requestIfNeeded { !Task.isCancelled } }
                }
            }
            .fluidOutlinedButton()
            .disabled(self.permission.isRequesting)

            Text("macOS requires Screen & System Audio Recording access.")
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var windowControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(self.windows) { window in
                        Button {
                            self.settings.screenshotWindow = window
                        } label: {
                            if self.settings.screenshotWindow?.isSameLiveWindow(as: window) == true {
                                Label(self.windowLabel(window), systemImage: "checkmark")
                            } else {
                                Text(self.windowLabel(window))
                            }
                        }
                    }
                } label: {
                    Text(self.settings.screenshotWindow?.label ?? "Choose a Window")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .fluidDropdownStyle()
                .accessibilityLabel("Window to capture")
                .accessibilityValue(self.settings.screenshotWindow?.label ?? "No window selected")
                .disabled(self.isLoadingWindows || self.windows.isEmpty)

                Button("Refresh Windows") { self.refreshRequest += 1 }
                    .fluidOutlinedButton()
                    .fixedSize()
                    .disabled(self.isLoadingWindows)
            }

            if self.isLoadingWindows {
                Text("Finding open windows…").foregroundStyle(self.theme.palette.secondaryText)
            } else if let error = self.windowError {
                Text(error).foregroundStyle(self.theme.palette.warning)
            } else if self.windows.isEmpty {
                Text("No windows are available. Open a window and refresh the list.")
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
    }

    private func windowLabel(_ window: ScreenshotWindow) -> String {
        let isDuplicate = self.windows.contains { $0.id != window.id && $0.label == window.label }
        return isDuplicate ? "\(window.label) (Window \(window.id))" : window.label
    }

    private func refreshWindows() async {
        guard self.windowRefreshID != nil else {
            self.windows = []
            self.windowError = nil
            self.isLoadingWindows = false
            return
        }

        self.isLoadingWindows = true
        self.windowError = nil
        do {
            let windows = try await ScreenshotCapture.availableWindows()
            guard !Task.isCancelled else { return }
            self.windows = windows
        } catch {
            guard !Task.isCancelled else { return }
            self.windows = []
            self.windowError = error.localizedDescription
        }
        self.isLoadingWindows = false
    }
}
