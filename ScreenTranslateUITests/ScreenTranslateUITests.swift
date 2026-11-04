import XCTest

final class ScreenTranslateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 300 }

    func testRealShareExtensionFillsScreenAndReturnsToInvokingApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset", "--ui-test-share", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let source = app.buttons["share.test.present"]
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        openExtension(app, source: source)
        let original = app.buttons["result.original"]
        guard original.waitForExistence(timeout: 60) else {
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.name = "系统扩展未生成识别结果"; failure.lifetime = .keepAlways; add(failure)
            XCTFail(app.debugDescription)
            return
        }
        let canvas = app.otherElements["result.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        guard canvas.frame.height >= app.frame.height * 0.97, canvas.frame.width >= app.frame.width * 0.97 else {
            failWithScreenshot(app, name: "系统共享容器未覆盖屏幕")
            return
        }
        XCTAssertFalse(source.isHittable)
        original.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Show Translation"), object: original)
        guard XCTWaiter.wait(for: [changed], timeout: 15) == .completed else {
            failWithScreenshot(app, name: "原图切换未响应")
            return
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "真实系统扩展-全屏覆盖来源界面"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["result.close"].tap()
        guard waitUntilHittable(source) else { failWithScreenshot(app, name: "叉号关闭后返回失败"); return }
        openExtension(app, source: source)
        XCTAssertTrue(original.waitForExistence(timeout: 60))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.94))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.60)))
        if !waitUntilHittable(source) { failWithScreenshot(app, name: "上滑后返回失败") }
    }

    func testHistoryTabOnlyExistsWhenHistorySavingIsEnabled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.tabBars.buttons["History"].exists)
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["settings.history"]
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        // SwiftUI exposes both the containing row and its UISwitch. Tapping
        // the row's centre hits its label on iOS 26 rather than the control.
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 10), app.debugDescription)
        toggle.switches.firstMatch.tap()
        XCTAssertFalse(app.tabBars.buttons["History"].exists)
    }

    private func openExtension(_ app: XCUIApplication, source: XCUIElement) {
        source.tap()
        // Share extensions appear in the app row, not the Action list below it.
        let shareButton = app.buttons["Translate Screen"].firstMatch
        let shareCell = app.cells.containing(.staticText, identifier: "Translate Screen").firstMatch
        for _ in 0..<5 {
            if shareButton.waitForExistence(timeout: 2), shareButton.isHittable { shareButton.tap(); return }
            if shareCell.exists, shareCell.isHittable { shareCell.tap(); return }
            app.swipeUp()
        }
        XCTFail("Share extension was not discoverable in the system app row.\n" + app.debugDescription)
    }

    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)], timeout: 45) == .completed
    }

    private func failWithScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        XCTFail(name + "\n" + app.debugDescription)
    }
}
