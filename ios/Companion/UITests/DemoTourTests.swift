import XCTest

// Scripted demo shots for the video. Each test is one shot, driven like a person would (taps and typing), with
// pauses so the screen can be read. Run one at a time while recording the simulator, for example:
//   xcrun simctl io booted recordVideo shot.mp4 &
//   xcodebuild test-without-building ... -only-testing:CompanionUITests/DemoTourTests/test2_FindSlippers
// Launches with -showTouches so taps appear as circles. Sample data, so the SAMPLE DATA badge stays on screen.
// Not part of the accessibility gate; skipped unless SOUGHT_DEMO=1 is set for the test run.

final class DemoTourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOUGHT_DEMO"] == "1", "Demo shots run only for recording")
        continueAfterFailure = true
    }

    private func launch(splash: Bool = false, _ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-useSampleData", "YES", "-showTouches", "YES", "-mockLoadDelay", "0.6", "-mockState", "exploring"]
            + (splash ? [] : ["-noSplash", "YES"]) + extra
        app.launch()
    }

    private func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }
    private func button(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch }

    func test1_SplashAndHome() {
        launch(splash: true)
        pause(4.5)
        app.swipeUp(velocity: .slow)
        pause(1.5)
        app.swipeDown(velocity: .slow)
        pause(1.5)
    }

    func test2_FindSlippers() {
        launch()
        pause(2)
        let field = app.textFields["searchField"]
        field.tap()
        pause(0.4)
        field.typeText("find my slippers")
        pause(0.6)
        app.keyboards.buttons["search"].firstMatch.exists ? app.keyboards.buttons["search"].tap() : field.typeText("\n")
        pause(2.5)
        app.buttons["confirmFind"].tap()
        pause(14)                       // searching, guiding with the distance counting down, found
        app.buttons["findDone"].tap()
        pause(1.5)
    }

    func test3_ItemLogAndDetail() {
        launch()
        pause(1.5)
        app.buttons["tab-items"].tap()
        pause(2)
        app.swipeUp(velocity: .slow)
        pause(1.5)
        app.swipeDown(velocity: .slow)
        pause(1)
        let card = app.descendants(matching: .any).matching(identifier: "item-obj_sample0007").firstMatch
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        pause(3)
        app.swipeUp(velocity: .slow)
        pause(1.5)
        button("Close").tap()
        pause(1.5)
    }

    func test4_MapAndPin() {
        launch()
        pause(1.5)
        app.buttons["tab-map"].tap()
        pause(2)
        button("Kitchen").tap()
        pause(2)
        button("Fridge").tap()
        pause(2.5)
        button("Close summary").tap()
        pause(1)
        button("All").tap()
        pause(1.5)
        button("Pin something").tap()
        pause(1.5)
        let map = app.otherElements["Floor map"].exists ? app.otherElements["Floor map"] : app.windows.firstMatch
        let from = map.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
        from.press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)))
        pause(1.5)
        button("Pin here").tap()
        pause(1.5)
        let name = app.textFields["Name of the item"]
        name.tap()
        name.typeText("TV remote")
        pause(0.8)
        let note = app.textFields["Note"].exists ? app.textFields["Note"] : app.textViews["Note"]
        note.tap()
        note.typeText("Under the blue cushion")
        pause(1)
        button("Save pin").tap()
        pause(3)
    }

    func test5_ComeToMe() {
        launch()
        pause(2)
        app.buttons["callButton"].tap()
        pause(2)
        button("I\u{2019}m near the sofa").tap()
        pause(9)
        button("Done").tap()
        pause(1.5)
    }

    func test6_ActivityLog() {
        launch()
        pause(2)
        app.descendants(matching: .any).matching(identifier: "activityCard").firstMatch.tap()
        pause(2)
        button("Metal Water Bottle moved").tap()
        pause(3)
        app.swipeUp(velocity: .slow)
        pause(2)
    }

    func test7_NameThenFind() {
        launch(["-mockUnnamed", "YES"])
        pause(2.5)
        app.descendants(matching: .any).matching(identifier: "namePrompt").firstMatch.tap()
        pause(2)
        let field = app.textFields["Name for this item"]
        field.tap()
        field.typeText("Slippers")
        pause(0.8)
        button("Save name").tap()
        pause(1.8)
        let field2 = app.textFields["Name for this item"]
        field2.tap()
        field2.typeText("Desk lamp")
        pause(0.8)
        button("Save name").tap()
        pause(1.8)
        button("Done").tap()
        pause(1.5)
        let search = app.textFields["searchField"]
        search.tap()
        search.typeText("find my slippers\n")
        pause(2.5)
        app.buttons["confirmFind"].tap()
        pause(13)
        app.buttons["findDone"].tap()
        pause(1.5)
    }
}
