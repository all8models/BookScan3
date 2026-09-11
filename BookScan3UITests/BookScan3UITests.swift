import XCTest

final class BookScan3UITests: XCTestCase {
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testReviewDraftAdjustSaveAndReopenOriginal() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--spread-fixture"]
        app.launchEnvironment["BOOKSCAN_TEST_ID"] = UUID().uuidString
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let book = app.descendants(matching: .any)["bookRow-양면 경계 테스트"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        capture(app, "Library")
        book.tap()
        let resume = app.buttons["resumeSpread"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        let save = app.buttons["saveSpread"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["spreadCanvas"].exists)
        // Nudge a selected corner to exercise the accessible editor and real re-render.
        app.buttons["선택한 점 오른쪽 이동"].tap()
        capture(app, "Spread Review")
        save.tap()
        XCTAssertTrue(app.buttons["startScan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 5))
        capture(app, "Page Grid")
        app.staticTexts["1"].tap()
        let recrop = app.buttons["원본에서 경계 다시 조정"]
        XCTAssertTrue(recrop.waitForExistence(timeout: 5))
        capture(app, "Page Detail")
        recrop.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        app.buttons["나중에"].tap()
        app.buttons["완료"].firstMatch.tap()
        app.buttons["선택"].tap()
        app.staticTexts["1"].tap()
        app.buttons["삭제 (1)"].tap()
        app.alerts.buttons["삭제"].tap()
        XCTAssertTrue(app.buttons["startScan"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["2"].exists)
    }

    @MainActor
    func testCreateBookAndOpenScanner() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let create = app.buttons["createBook"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("Scanner UI Test")
        app.alerts.buttons["만들기"].tap()
        let scan = app.buttons["startScan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        XCTAssertTrue(app.buttons["설정"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["사진에서 가져오기"].exists)
        capture(app, "Camera")
        app.buttons["서재"].firstMatch.tap()
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "iPad Library"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
