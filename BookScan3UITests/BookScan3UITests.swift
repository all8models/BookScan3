import XCTest

final class BookScan3UITests: XCTestCase {
    @MainActor
    func testReviewDraftAdjustSaveAndReopenOriginal() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--spread-fixture"]
        app.launchEnvironment["BOOKSCAN_TEST_ID"] = UUID().uuidString
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let resume = app.buttons["resumeSpread"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        resume.tap()
        let save = app.buttons["saveSpread"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["spreadCanvas"].exists)
        // Nudge a selected corner to exercise the accessible editor and real re-render.
        app.buttons["선택한 점 오른쪽 이동"].tap()
        save.tap()
        XCTAssertTrue(app.buttons["startScan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["02"].waitForExistence(timeout: 5))
        app.staticTexts["01"].tap()
        let recrop = app.buttons["원본에서 경계 다시 조정"]
        XCTAssertTrue(recrop.waitForExistence(timeout: 5))
        recrop.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        app.buttons["나중에"].tap()
    }

    @MainActor
    func testCreateBookAndOpenScanner() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
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
        XCTAssertTrue(app.staticTexts["좋은 스캔의 시작"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["사진에서 가져오기"].exists)
        app.buttons["완료"].firstMatch.tap()
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "iPad Library"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
