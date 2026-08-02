import XCTest

/// Drives the three screens reachable from the chat.
///
/// `-UITestMode` is what makes these deterministic: it swaps the Keychain for an in-memory one,
/// the settings store for one that does not persist, and the catalogue client for a fixed one. The
/// last is not optional — a XCUITest launches the app as its own process with no test code linked,
/// so `URLProtocol` stubbing cannot reach it, and without the swap these tests would depend on
/// openrouter.ai being up and on the account's model list not changing.
/// `@MainActor` because every XCUITest API — `XCUIApplication`, `XCUIElement`, `tap()` — is
/// main-actor isolated under Swift 6 strict concurrency. XCTest already runs these methods on the
/// main thread; saying so is what keeps the target building without a wall of isolation warnings.
@MainActor
class ScreensUITestCase: XCTestCase {
    func launch(apiKey: String? = nil, failKeychainWrites: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-UITestMode", "-SignedIn"]
        if failKeychainWrites { arguments.append("-FailKeychainWrites") }
        if let apiKey { arguments += ["-OpenRouterAPIKey", apiKey] }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(
            app.buttons["settingsButton"].waitForExistence(timeout: 20),
            "the signed-in scaffold never appeared"
        )
        return app
    }

    /// Scrolls until `element` is in the hierarchy.
    ///
    /// A SwiftUI `List` builds its rows lazily, so a row below the fold does not merely fail
    /// `isHittable` — it does not exist at all. Every one of these screens is taller than a phone,
    /// so without this the assertions would only ever cover the top of each of them.
    @discardableResult
    func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        swipes: Int = 12
    ) -> Bool {
        for _ in 0..<swipes {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    /// Flips a `Toggle` and waits for it to report the new state.
    ///
    /// Tapped near the trailing edge rather than at the element's centre: a SwiftUI `Toggle` in a
    /// `List` reports a frame spanning the whole row, so a centre tap lands on the label and the
    /// switch does not move — which reads as a filtering bug rather than as a missed tap.
    func flip(_ identifier: String, in app: XCUIApplication) {
        let toggle = app.switches[identifier]
        XCTAssertTrue(reveal(toggle, in: app), "\(identifier) is not on screen")
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertNotEqual(toggle.value as? String, before, "\(identifier) did not change")
    }

    /// The element carrying `identifier`, whatever XCUITest decided its type is.
    ///
    /// A row built with `.accessibilityElement(children: .combine)` surfaces as an `other` on one
    /// OS build and as a `staticText` on another; querying by type would make these tests fail for
    /// a reason that has nothing to do with the app.
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

final class ModelPickerUITests: ScreensUITestCase {
    @discardableResult
    private func openPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["modelPickerButton"].tap()
        let gpt = app.buttons["modelRow-openai/gpt-4o"]
        XCTAssertTrue(gpt.waitForExistence(timeout: 15), "the catalogue never rendered")
        return gpt
    }

    func testListsPricedModelsWithTheirCapabilities() {
        let app = launch()
        let gpt = openPicker(app)

        XCTAssertTrue(gpt.label.contains("GPT-4o"), "the row must name the model: \(gpt.label)")
        XCTAssertTrue(gpt.label.contains("128K"), "context window missing: \(gpt.label)")
        XCTAssertTrue(gpt.label.contains("Tools"), "capability badge missing: \(gpt.label)")
        XCTAssertTrue(gpt.label.contains("Vision"), "capability badge missing: \(gpt.label)")
        XCTAssertTrue(gpt.label.contains("2.50"), "price per million missing: \(gpt.label)")
    }

    /// The assertion this screen exists for. `openrouter/auto` carries the `-1` pricing sentinel:
    /// it picks an upstream per request, so any cost shown against it would be invented.
    func testVariablePricedRoutersAreExcluded() {
        let app = launch()
        openPicker(app)

        XCTAssertFalse(
            app.buttons["modelRow-openrouter/auto"].exists,
            "a model whose price is unknowable must never appear in a list that shows prices"
        )
        XCTAssertTrue(
            reveal(app.staticTexts["modelPickerExclusionNote"], in: app),
            "the exclusion has to be explained, not silently applied"
        )
    }

    func testFreeOnlyFilterNarrowsTheList() {
        let app = launch()
        openPicker(app)
        flip("modelFilterFree", in: app)

        let free = app.buttons["modelRow-inclusionai/ling-3.0-flash:free"]
        XCTAssertTrue(free.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["modelRow-openai/gpt-4o"].exists, "a paid model is not free")
    }

    /// Free *and* vision matches nothing in this catalogue, and "nothing matched" has to be said
    /// rather than shown as a blank screen.
    func testAnImpossibleFilterCombinationSaysSo() {
        let app = launch()
        openPicker(app)
        flip("modelFilterFree", in: app)
        flip("modelFilterVision", in: app)

        XCTAssertTrue(reveal(app.staticTexts["modelPickerEmpty"], in: app))
    }

    func testSelectingAModelUpdatesTheSetting() {
        let app = launch()
        openPicker(app)

        let free = app.buttons["modelRow-inclusionai/ling-3.0-flash:free"]
        XCTAssertTrue(free.waitForExistence(timeout: 10))
        free.tap()

        app.buttons["settingsButton"].tap()
        let row = element("defaultModelRow", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(
            row.label.contains("inclusionai/ling-3.0-flash:free"),
            "the choice must reach PipelineSettings: \(row.label)"
        )
    }
}

final class SettingsUITests: ScreensUITestCase {
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["apiKeyOrigin"].waitForExistence(timeout: 10))
    }

    /// Where the key came from is the thing a user cannot otherwise find out, and it is the
    /// difference between "my key is missing" and "the build supplied one".
    func testAnAbsentKeyIsReportedAsAbsentRatherThanBlank() {
        let app = launch()
        openSettings(app)

        XCTAssertEqual(app.staticTexts["apiKeyOrigin"].label, "Not configured")
        XCTAssertEqual(app.staticTexts["apiKeyMasked"].label, "No key set")
        XCTAssertFalse(
            app.buttons["apiKeyDeleteButton"].exists,
            "there is nothing to delete"
        )
    }

    func testAnInjectedKeyIsMaskedAndItsOriginNamed() {
        let app = launch(apiKey: "sk-or-v1-abcdefghijklmnop1234")
        openSettings(app)

        XCTAssertEqual(app.staticTexts["apiKeyOrigin"].label, "Injected by a test run")
        let masked = app.staticTexts["apiKeyMasked"].label
        XCTAssertEqual(masked, "sk-or-v1…1234")
        XCTAssertFalse(masked.contains("abcdefghij"), "the middle of the key must not be shown")
        XCTAssertTrue(app.buttons["apiKeyDeleteButton"].exists)
    }

    /// `limit: null` means unlimited. Rendering it as `$0.0000` would tell a funded account it is
    /// out of credit.
    func testANullLimitRendersAsUnlimitedRatherThanZero() {
        let app = launch()
        openSettings(app)

        let remaining = app.staticTexts["keyStatusRemaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 10))
        XCTAssertTrue(remaining.label.contains("Unlimited"), "got \(remaining.label)")
        XCTAssertFalse(app.staticTexts["keyStatusExhausted"].exists)
    }

    /// Saving and deleting are the only two writes this screen makes, and both go through
    /// `AppSecrets` rather than touching the Keychain directly. Under `-UITestMode` the store is
    /// in memory, so the round trip is real without the device's Keychain being involved.
    func testSavingAKeyThenDeletingItLeavesTheAppUsable() {
        let app = launch()
        openSettings(app)

        XCTAssertEqual(app.staticTexts["apiKeyMasked"].label, "No key set")
        let save = app.buttons["apiKeySaveButton"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "an empty field must not offer to save nothing")

        let field = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText("sk-or-v1-typedbyhand9876")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertEqual(app.staticTexts["apiKeyMasked"].label, "sk-or-v1…9876")
        XCTAssertEqual(app.staticTexts["apiKeyOrigin"].label, "Stored on this device")

        let delete = app.buttons["apiKeyDeleteButton"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertEqual(app.staticTexts["apiKeyMasked"].label, "No key set")
        XCTAssertEqual(app.staticTexts["apiKeyOrigin"].label, "Not configured")
    }

    /// A Keychain that refuses the write. The failure has to reach the screen: an app that silently
    /// swallows it leaves the user believing their key is saved, and the 401 arrives one screen
    /// later pointing nowhere near the cause.
    func testAKeychainWriteThatFailsIsShownRatherThanSwallowed() {
        let app = launch(failKeychainWrites: true)
        openSettings(app)

        let field = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText("sk-or-v1-cannotbesaved")
        app.buttons["apiKeySaveButton"].tap()

        let error = app.staticTexts["apiKeyError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "the failure never reached the screen")
        XCTAssertTrue(error.label.contains("Keychain"), "got \(error.label)")
        XCTAssertEqual(
            app.staticTexts["apiKeyMasked"].label,
            "No key set",
            "a refused write must not be reported as a stored key"
        )
    }

    /// Typing a ceiling and pressing Set is the other half of the budget control; the toggle only
    /// seeds a default. A ceiling the field accepts but never applies is worse than no field.
    func testTypingACeilingAppliesIt() {
        let app = launch()
        openSettings(app)

        let ceiling = element("budgetCeiling", in: app)
        XCTAssertTrue(reveal(ceiling, in: app), "the budget section never appeared")
        flip("budgetLimitToggle", in: app)

        let field = app.textFields["budgetCeilingField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // The toggle seeds "5"; clear it rather than typing on the end of it.
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        field.typeText("12.5")

        let apply = app.buttons["budgetCeilingApply"]
        XCTAssertTrue(apply.isEnabled, "a numeric value must be applicable")
        apply.tap()

        XCTAssertTrue(
            element("budgetCeiling", in: app).label.contains("$12.50"),
            "got \(element("budgetCeiling", in: app).label)"
        )
    }

    /// The temperature shown, parsed back out of the row's label.
    private func temperature(in app: XCUIApplication) -> Double? {
        let label = element("temperatureValue", in: app).label
        guard let match = label.split(separator: " ").compactMap({ Double($0) }).last else {
            return nil
        }
        return match
    }

    /// The slider is the one control that can reach a `precondition` which traps in release, so
    /// both ends of its travel are exercised rather than only the middle.
    ///
    /// Asserted as a range rather than as an exact `2.00`/`0.00`. `adjust(toNormalizedSliderPosition:)`
    /// synthesises a drag, and a drag can stop one `step` — 0.05 here — short of the end of the
    /// track depending on where the row landed after scrolling. The claim that matters is that
    /// both ends of the travel are reachable and that neither escapes `0...2`, which is what the
    /// `precondition` inside `LLMRequest.init` would trap on. The clamp itself is asserted
    /// exactly, and without a gesture, in `TurnSettings`' own tests.
    func testTemperatureStaysInsideTheRangeTheProviderEnforces() {
        let app = launch()
        openSettings(app)

        let value = element("temperatureValue", in: app)
        XCTAssertTrue(reveal(value, in: app), "the generation section never appeared")
        XCTAssertEqual(temperature(in: app), 0.7, "the default should show: \(value.label)")

        let slider = app.sliders["temperatureSlider"]
        XCTAssertTrue(slider.exists)
        slider.adjust(toNormalizedSliderPosition: 1.0)
        let top = try? XCTUnwrap(temperature(in: app))
        XCTAssertNotNil(top, "no number in \(value.label)")
        XCTAssertGreaterThanOrEqual(top ?? 0, 1.9, "the top of the range: \(value.label)")
        XCTAssertLessThanOrEqual(top ?? 99, 2.0, "the provider traps above 2: \(value.label)")

        slider.adjust(toNormalizedSliderPosition: 0.0)
        let bottom = try? XCTUnwrap(temperature(in: app))
        XCTAssertNotNil(bottom, "no number in \(value.label)")
        XCTAssertLessThanOrEqual(bottom ?? 99, 0.1, "the bottom of the range: \(value.label)")
        XCTAssertGreaterThanOrEqual(bottom ?? -1, 0.0, "the provider traps below 0: \(value.label)")
    }

    func testPipelineFlagsToggle() {
        let app = launch()
        openSettings(app)

        let cache = app.switches["cacheToggle"]
        XCTAssertTrue(reveal(cache, in: app), "the pipeline section never appeared")
        XCTAssertEqual(cache.value as? String, "1", "the cache is on by default")
        flip("cacheToggle", in: app)
        XCTAssertEqual(cache.value as? String, "0")
    }

    /// A toggle that instantly refused every message would teach the user to leave the budget
    /// layer alone, so switching the limit on seeds a real, usable ceiling rather than zero.
    func testTurningOnTheBudgetSeedsARealCeilingRatherThanZero() {
        let app = launch()
        openSettings(app)

        let ceiling = element("budgetCeiling", in: app)
        XCTAssertTrue(reveal(ceiling, in: app), "the budget section never appeared")
        XCTAssertTrue(ceiling.label.contains("Unlimited"), "got \(ceiling.label)")

        flip("budgetLimitToggle", in: app)
        XCTAssertTrue(
            element("budgetCeiling", in: app).label.contains("$5.00"),
            "a ceiling of zero would refuse the very next message"
        )
        XCTAssertTrue(element("budgetSpent", in: app).label.contains("$0.0000"))
    }
}

final class DiagnosticsUITests: ScreensUITestCase {
    /// Before anything has been sent, every stage the pipeline declares is unreached — and saying
    /// so is the whole point of `PipelineTrace.unreached`. A package that silently did nothing
    /// looks exactly like one that was never wired in.
    func testEveryDeclaredStageIsVisibleBeforeAnythingRuns() {
        let app = launch()
        app.buttons["diagnosticsButton"].tap()

        XCTAssertTrue(
            element("diagnosticsDuration", in: app).waitForExistence(timeout: 15),
            "the summary never rendered"
        )
        XCTAssertFalse(
            app.staticTexts["unreachedNone"].exists,
            "nothing has run, so no stage can have reported"
        )
        // First, middle and last of the declared order, each reached by scrolling — a screen that
        // enumerates the pipeline has to keep going past the fold.
        for stage in ["promptTemplate", "providerRouting", "tracing"] {
            XCTAssertTrue(
                reveal(element("unreachedStage-\(stage)", in: app), in: app, swipes: 20),
                "\(stage) is not listed as unreached"
            )
        }
    }

    func testTheUnreachedSectionNamesTheOwningPackage() {
        let app = launch()
        app.buttons["diagnosticsButton"].tap()

        let row = element("unreachedStage-promptTemplate", in: app)
        XCTAssertTrue(reveal(row, in: app))
        XCTAssertTrue(row.label.contains("Prompt template"), "got \(row.label)")
        XCTAssertTrue(row.label.contains("PromptTemplateKit"), "got \(row.label)")
    }

    func testDiagnosticsIsReachableAndDismissable() {
        let app = launch()
        app.buttons["diagnosticsButton"].tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 10))

        app.navigationBars["Diagnostics"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["sendButton"].waitForExistence(timeout: 10))
    }
}
