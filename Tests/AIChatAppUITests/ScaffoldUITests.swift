import XCTest

/// Drives the real screens through a deterministic launch.
///
/// `-UITestMode` swaps the Keychain for an in-memory one and forces biometrics unavailable, so a
/// run on a machine where an earlier launch left a key or a session behind still starts from the
/// same place. Without that, these tests pass locally and fail on the next machine.
/// `@MainActor` because every XCUITest API — `XCUIApplication`, `XCUIElement`, `tap()` — is
/// main-actor isolated under Swift 6 strict concurrency. XCTest already runs these methods on the
/// main thread; saying so is what keeps the target building without a wall of isolation warnings.
@MainActor
final class LoginFlowUITests: XCTestCase {
    private func launch(signedIn: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode"] + (signedIn ? ["-SignedIn"] : [])
        app.launch()
        return app
    }

    func testLaunchesToLoginWhenNoSessionExists() {
        let app = launch()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["emailField"].exists)
        XCTAssertTrue(app.secureTextFields["passphraseField"].exists)
    }

    func testEmptyCredentialsAreRefusedWithAReasonRatherThanSilently() {
        let app = launch()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 10))
        app.buttons["signInButton"].tap()

        let error = app.staticTexts["loginError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(error.label.isEmpty, "a rejected sign-in must say why")
    }

    func testWrongCredentialsDoNotSignIn() {
        let app = launch()
        let email = app.textFields["emailField"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("someone@else.test")

        app.secureTextFields["passphraseField"].tap()
        app.secureTextFields["passphraseField"].typeText("nope")
        app.buttons["signInButton"].tap()

        XCTAssertTrue(app.staticTexts["loginError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["messageField"].exists, "the chat must not be reachable")
    }

    func testDemoCredentialsReachTheChatScreen() {
        let app = launch()
        let email = app.textFields["emailField"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("demo@aichat.app")

        app.secureTextFields["passphraseField"].tap()
        app.secureTextFields["passphraseField"].typeText("letmein")
        app.buttons["signInButton"].tap()

        XCTAssertTrue(app.staticTexts["chatEmptyState"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["signOutButton"].exists)
    }

    /// A restored session must land in the chat, not bounce through login.
    func testRestoredSessionSkipsLogin() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.staticTexts["chatEmptyState"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["signInButton"].exists)
    }

    func testSignOutReturnsToLogin() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.buttons["signOutButton"].waitForExistence(timeout: 15))
        app.buttons["signOutButton"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 5))
    }

    /// Send stays disabled on an empty draft, so an empty turn can never be billed.
    func testSendIsDisabledUntilSomethingIsTyped() {
        let app = launch(signedIn: true)
        XCTAssertTrue(app.staticTexts["chatEmptyState"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["sendButton"].isEnabled)
    }
}
