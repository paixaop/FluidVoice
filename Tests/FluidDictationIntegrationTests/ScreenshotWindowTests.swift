import CoreGraphics
import Foundation
@testable import FluidVoice_Debug
import XCTest

final class ScreenshotWindowTests: XCTestCase {
    func testLiveSelectionSurvivesTitleChanges() {
        let saved = self.window(id: 1, title: "First Document")
        let renamed = self.window(id: 1, title: "Renamed Document")
        let sameTitle = self.window(id: 2, title: "First Document")
        XCTAssertEqual(saved.matchingWindow(in: [sameTitle, renamed], originalProcessIsRunning: true), renamed)
        XCTAssertNil(saved.matchingWindow(in: [sameTitle], originalProcessIsRunning: true))
    }

    func testRelaunchRequiresAUniqueTitleInTheSameApp() {
        let saved = self.window(id: 1, title: "Project")
        let reopened = self.window(id: 2, processID: 20, title: "Project")
        let duplicate = self.window(id: 3, processID: 20, title: "Project")
        let otherApp = self.window(id: 4, processID: 30, bundleIdentifier: "test.other", title: "Project")
        XCTAssertEqual(saved.matchingWindow(in: [reopened, otherApp], originalProcessIsRunning: false), reopened)
        XCTAssertNil(saved.matchingWindow(in: [reopened, duplicate], originalProcessIsRunning: false))
        XCTAssertNil(saved.matchingWindow(in: [otherApp], originalProcessIsRunning: false))
    }

    func testUntitledWindowDoesNotRebindAfterRelaunch() {
        let saved = self.window(id: 1, title: nil)
        let reusedID = self.window(id: 1, processID: 20, title: nil)
        XCTAssertNil(saved.matchingWindow(in: [reusedID], originalProcessIsRunning: false))
    }

    private func window(id: CGWindowID, processID: pid_t = 10, bundleIdentifier: String = "test.editor", title: String?) -> ScreenshotWindow {
        ScreenshotWindow(
            id: id,
            processID: processID,
            launchDate: Date(timeIntervalSinceReferenceDate: TimeInterval(processID)),
            bundleIdentifier: bundleIdentifier,
            applicationName: "Editor",
            title: title
        )
    }
}
