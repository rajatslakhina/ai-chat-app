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

    /// The signed-in root is the chat list now, so reaching the composer takes one more tap.
    private func openChat(_ app: XCUIApplication) {
        let newChat = element("newChatButton", in: app)
        XCTAssertTrue(newChat.waitForExistence(timeout: 20))
        newChat.tap()
    }

    /// A SwiftUI toolbar button does not reliably surface as a `button`, so it is found by
    /// identifier across every type.
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

        // Signing in lands on the list, and the list is where a chat is started from.
        openChat(app)
        // 20 rather than 15, matching every other reachability wait in this file.
        //
        // This assertion is about whether login *reaches* the chat screen, not how fast. At 15 it
        // was the tightest wait here and it timed out twice — once on 2026-08-25 and again on
        // 2026-08-26 — both times in the full suite, after the simulator had just run 750-odd unit
        // tests, and both times passing in about 13s when the UI target is run on its own. The
        // margin was two-to-one against a machine under load, which is not a margin.
        XCTAssertTrue(app.staticTexts["chatEmptyState"].waitForExistence(timeout: 20))
    }

    /// A restored session must land in the app, not bounce through login.
    func testRestoredSessionSkipsLogin() {
        let app = launch(signedIn: true)
        XCTAssertTrue(element("newChatButton", in: app).waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["signInButton"].exists)
    }

    /// Sign out moved to the profile screen, where the account it ends actually lives.
    func testSignOutReturnsToLogin() {
        let app = launch(signedIn: true)
        let profile = element("profileButton", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 20))
        profile.tap()
        XCTAssertTrue(app.buttons["signOutButton"].waitForExistence(timeout: 15))
        app.buttons["signOutButton"].tap()
        XCTAssertTrue(app.buttons["signInButton"].waitForExistence(timeout: 10))
    }

    /// Send stays disabled on an empty draft, so an empty turn can never be billed.
    func testSendIsDisabledUntilSomethingIsTyped() {
        let app = launch(signedIn: true)
        openChat(app)
        XCTAssertTrue(app.staticTexts["chatEmptyState"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["sendButton"].isEnabled)
    }
}
