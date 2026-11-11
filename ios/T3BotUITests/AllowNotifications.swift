import XCTest

/// Simulator only, for screen checks: launches T3 Bot and answers iOS's notification question with Allow, so pushes
/// sent with `simctl push` show as they would on a phone. Run with
/// `xcodebuild test -scheme T3Bot -only-testing:T3BotUITests/AllowNotifications/testAllow`.
final class AllowNotifications: XCTestCase {
    func testAllow() {
        let app = XCUIApplication()
        app.launchArguments = ProcessInfo.processInfo.environment["T3BOT_UITEST_ARGS"]?.split(separator: " ").map(String.init) ?? []
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The simulator may run in another language: Allow, Autoriser, Erlauben, Permitir.
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Autoriser", "Erlauben", "Permitir", "Consenti"])).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 20), "the notification question did not show")
        allow.tap()
        sleep(2)
    }
}
