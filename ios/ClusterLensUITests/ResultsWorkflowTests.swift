import XCTest

final class ResultsWorkflowTests: XCTestCase {
    func testColumnsNestedInspectorAndNextPageWithFictionalData() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--synthetic-ui"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture_store"].waitForExistence(timeout: 10))
        app.staticTexts["fixture_store"].tap()
        app.staticTexts["orders"].tap()
        let columns = app.buttons["resultColumns"]
        XCTAssertTrue(columns.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["resultCell_0_item"].exists)
        capture(app, "Actual collection results — fictional data")
        columns.tap()
        app.buttons["resultColumn_status"].tap()
        columns.tap()
        app.buttons["resultColumn_tags"].tap()
        let tags = app.buttons["resultCell_0_tags"]
        XCTAssertTrue(tags.waitForExistence(timeout: 5))
        tags.tap()
        let array = app.buttons["inspectorNode_0_Value"]
        XCTAssertTrue(array.waitForExistence(timeout: 5))
        array.tap()
        XCTAssertTrue(app.staticTexts["\"Fictional\""].waitForExistence(timeout: 5))
        capture(app, "Actual nested array inspector — fictional data")
        app.buttons["Done"].tap()
        app.buttons["inspectRecord_0"].tap()
        XCTAssertTrue(app.buttons["inspectorNode_0_Value"].waitForExistence(timeout: 5))
        app.buttons["inspectorNode_0_Value"].tap()
        app.buttons["inspectorNode_1_customer"].tap()
        XCTAssertTrue(app.staticTexts["\"Cedar Hill\""].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["null"].exists)
        capture(app, "Actual object inspector — null remains distinct")
        app.buttons["Done"].tap()
        let next = app.buttons["Next page"]
        if !next.isHittable { app.swipeDown() }
        next.tap()
        let secondPage = app.buttons["resultCell_0_item"]
        XCTAssertTrue(secondPage.waitForExistence(timeout: 5))
        let updated = NSPredicate(format: "label CONTAINS %@", "Fixture order 21")
        expectation(for: updated, evaluatedWith: secondPage)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["resultCell_0_tags"].exists, "Display columns survive page replacement")
        XCTAssertFalse(app.buttons["resultCell_0_status"].exists)
        capture(app, "Actual next page — chosen columns preserved")
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
