import XCTest

final class BookScan3UITests: XCTestCase {
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
