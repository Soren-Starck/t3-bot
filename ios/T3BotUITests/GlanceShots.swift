import XCTest

/// Simulator only, for screen checks: the real Dynamic Island, the lock screen with a Live Activity, and a
/// notification opened to its buttons, which no in-app screen can show. The pictures go to the folder in
/// T3BOT_SHOTS (TEST_RUNNER_T3BOT_SHOTS in xcodebuild's environment); NATIVE/glance.sh runs it and sends the push.
final class GlanceShots: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func shot(_ name: String) {
        guard let dir = env["T3BOT_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func lockButton() { XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton")) }

    func testGlances() {
        let app = XCUIApplication()
        app.launchArguments = (env["T3BOT_GLANCE_ARGS"] ?? "").split(separator: " ").map(String.init)
        app.launch()
        // The launch link sends a message, which starts the bot's Live Activity.
        sleep(6)
        XCUIDevice.shared.press(.home)
        sleep(3)
        shot("island")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // A long press on the island opens it.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.028)).press(forDuration: 1.2)
        sleep(1)
        shot("island-expanded")
        sleep(4)
        lockButton()
        sleep(2)
        lockButton()
        sleep(3)
        shot("lock-live")
        // glance.sh sends the push once lock-live.png exists.
        let note = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "pricing page")).firstMatch
        guard note.waitForExistence(timeout: 40) else { return XCTFail("the notification did not show") }
        sleep(2)
        shot("lock-notification")
        note.press(forDuration: 1.5)
        sleep(2)
        shot("notification-actions")
    }
}
