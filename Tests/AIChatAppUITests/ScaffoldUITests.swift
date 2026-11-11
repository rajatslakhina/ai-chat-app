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
    ///
    /// That tap can be dropped. A failing full-suite run on 2026-09-22 kept its screen, element tree
    /// and recording: the list had settled about 1.4s after sign-in, the tap was synthesized 0.3s
    /// later, and then nothing happened. No chat opened and no conversation row appeared, so
    /// `startChat` never ran; the month of failures read as "the chat opened and its empty state
    /// never appeared" was this. Starting a chat adds a row before it navigates, so an empty list
    /// with no composer is proof the action did not run, and only then is one more tap sent, inside
    /// a named activity so every dropped tap stays visible in the result bundle.
    private func openChat(_ app: XCUIApplication) {
        let newChat = element("newChatButton", in: app)
        XCTAssertTrue(newChat.waitForExistence(timeout: 20))
        newChat.tap()
        let opened = element("messageField", in: app).waitForExistence(timeout: 5)
        if !opened, element("chatListEmpty", in: app).exists {
            XCTContext.runActivity(named: "New chat tap was dropped: list still empty, tapping once more") { _ in
                newChat.tap()
            }
        }
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
        declinePasswordSave()

        // Signing in lands on the list, and the list is where a chat is started from.
        openChat(app)
        // 20 rather than 15, matching every other reachability wait in this file.
        //
        // This assertion is about whether login *reaches* the chat screen, not how fast. At 15 it
        // was the tightest wait here and it timed out twice — once on 2026-08-25 and again on
        // 2026-08-26 — both times in the full suite, after the simulator had just run 750-odd unit
        // tests, and both times passing in about 13s when the UI target is run on its own. The
        // margin was two-to-one against a machine under load, which is not a margin.
        //
        // It still fails intermittently in the full suite with the chat open and no empty state,
        // and nothing recorded what was on screen, so a failure now keeps the screen and the
        // element tree in the result bundle. Diagnostics only: the wait and the assertion are the
        // same ones as before.
        let reached = app.staticTexts["chatEmptyState"].waitForExistence(timeout: 20)
        if !reached {
            attachDiagnostics(of: app, named: "chatEmptyState never appeared")
        }
        XCTAssertTrue(reached)
    }

    /// iOS can offer to save the passphrase after a password sign-in. The offer belongs to
    /// SafariViewService, not the app, and while it is up it swallows taps on the chat list: on
    /// 2026-11-05 every failure of `testDemoCredentialsReachTheChatScreen` had a `Save Password?`
    /// alert from SafariViewService in the simulator log, and both New chat taps were dropped. The
    /// app's screenshot cannot show it. Decline the offer when it appears; nothing in the app changes.
    private func declinePasswordSave() {
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let notNow = service.buttons["Not Now"]
        // 10, not 4: on 2026-11-11 the offer came up 5.8s after the sign-in tap, with the machine under
        // load, after a 4s wait had already given up, and it swallowed the New chat tap.
        guard notNow.waitForExistence(timeout: 10) else { return }
        XCTContext.runActivity(named: "Declined the system Save Password? offer") { _ in
            notNow.tap()
        }
    }

    /// Keeps the screen and the element tree at the moment a wait gave up, in the result bundle.
    private func attachDiagnostics(of app: XCUIApplication, named name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name): screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name): element tree"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
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
