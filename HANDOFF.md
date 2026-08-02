# Handoff

Working state for picking this up cold. The [README](README.md) is the architecture; this is what
is true right now, what is broken, and what to do next.

Last updated: 2026-08-02.

---

## Where things are

- **Repo:** <https://github.com/rajatslakhina/ai-chat-app>, branch `main`, everything pushed.
- **Local:** `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/DevKnowledge/iOS Tasks/Portfolio Projects/AIChatApp`
- A SwiftUI iOS chat client for OpenRouter, built on 27 Swift packages from the
  [`llm-ecosystem-demo`](https://github.com/rajatslakhina/llm-ecosystem-demo) series.

**Read the README before changing anything.** It documents seven package symbol collisions that
break the build outright, and a page of package behaviour that cost real debugging. All of it is
verified rather than guessed.

## Gates

```bash
xcodegen generate
xcodebuild -project AIChatApp.xcodeproj -scheme AIChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/aichatapp-coverage-dd -skipMacroValidation test
swiftlint lint --strict
SKIP_TEST_RUN=1 COVERAGE_THRESHOLD=0 ./Scripts/coverage.sh
```

DerivedData must stay in `/tmp`. The project sits in an iCloud-synced folder and iCloud's extended
attributes make codesign fail with `resource fork, Finder information, or similar detritus not
allowed`.

Run `xcodegen generate` after adding **or deleting** any file. Deleting a snapshot reference
without regenerating fails the build with `Build input file cannot be found`.

**Never commit `Secrets.xcconfig`.** Before any push:

```bash
git diff --cached | grep -oE 'sk-or-v1-[a-f0-9]{40,}'
```

must return nothing.

## Current numbers

| Gate | Result |
|---|---|
| Unit + integration tests | 583 passing, 114 suites |
| UI tests (XCUITest) | **6 passing, 6 failing** |
| Build warnings | 0 |
| `swiftlint --strict` | 0 violations |
| Line coverage | 92.62% — **unit tests only** |

The 92.62% is not comparable to the 99.33% recorded earlier in the history: that figure included
the UI tests and predates the profile and history screens. Restoring a full-suite number needs the
UI tests fixed first.

---

## What is broken

### Six UI tests — start here

They assert a **two-level** navigation hierarchy (chat → destination). There are now **three**
(list → chat → destination). So the back button they tap is named for a different screen, and the
Diagnostics rows they look for sit one push deeper.

Failing: `DiagnosticsUITests` (3), `LoginFlowUITests.testDemoCredentialsReachTheChatScreen`,
`ModelPickerUITests` (2).

**The app itself is fine** — the list, profile, editing and persistence were all verified by hand
on the simulator. This is the tests' model of the hierarchy, not a defect in the feature.

Already tried and ruled out: an environment crash (real, fixed — `DiagnosticsView` read a
`ChatViewModel` the stack no longer had), a render loop (real, fixed — an `@Observable` was being
built inside `body`), and element-type queries (not the cause). What remains is genuinely the
navigation depth.

---

## What is left

Roughly in the order worth doing.

1. **Fix the six UI tests.** Bounded. See above.
2. **Full-suite coverage number.** Only meaningful once (1) is done.
3. **`AccentColor` is unused.** The asset exists and the design system references
   `Color.accentColor`, but nothing sets `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, so the
   system default blue renders. One line, but it visibly changes every tinted control — a
   deliberate decision, not a slip-in. The assistant avatar hardcodes the icon gradient for exactly
   this reason.
4. **A real corpus.** `AppKnowledge` is four passages about the app itself — enough to prove hybrid
   retrieval works, not a knowledge base.
5. **Effort is one value per provider.** `ReasoningEffortBox` is per-provider, not per-request:
   `LLMRequest` belongs to ProviderGatewayKit and cannot carry the field without forking a package
   27 things depend on. Two conversations sending simultaneously would share it. This app sends one
   turn at a time, so it is correct today and worth revisiting if that changes.
6. **CoreSpotlight.** `SpotlightRAGKit` ships `CoreSpotlightSearchIndex`, which would make the
   corpus searchable outside the app. Unused because it does not index reliably in a simulator, so
   the tests would be asserting against the host machine's state.
7. **Profile photos.** Avatars are monograms. A photo picker means a permission prompt, a privacy
   string and an image store.
8. **`foundation-model-provider-gateway` coverage** — ~50%, three simulated providers at 0%. The
   largest carried item across the whole package series, and a real multi-file effort.

---

## Traps that already cost time here

- **Guessing a value costs a build cycle.** It happened twice: a test epoch that was a day out (and
  every "Yesterday" assertion politely agreed with it), and an assumed `Date.FormatStyle` locale
  that rendered `31 July 2026` instead of `July 30, 2026`. Compute and verify.
- **A non-optional field added to a persisted struct** makes every blob written by an earlier build
  fail to decode — and the fallback presents that as "no data". Every added field is optional for
  this reason: `toolApprovalRequired`, `Conversation.effort`, `StoredMessage.createdAt`.
- **A view reading a non-optional `@Environment` traps rather than fails** when a test does not
  inject it. `ChatView` reads `ProfileStore` as optional precisely because of this.
- **Never construct an `@Observable` inside `body`.** Injecting a fresh one into the environment
  re-invalidates the view that built it and the screen never settles. The symptom was Diagnostics
  rendering nothing at all.
- **Snapshot record mode is `.never` on purpose.** Set it to `.missing` for one run and put it
  back. `.all` rewrites unrelated references that had no reason to change.
- **`swift test`'s tail prints `Test run with 0 tests in 0 suites` for an XCTest-only package** —
  that line belongs to the swift-testing runner and the real tally is above it. Reading the tail
  alone reports a healthy package as broken.
- **SwiftLint limits are fixed by extracting, never by raising.** Both `type_body_length` and
  `file_length` were hit; each was solved by moving code to an extension or a new file.
- **`StubURLProtocol`'s queue is static.** Any suite that drives it must be `.serialized`, or tests
  steal each other's canned responses — and the symptom surfaces in an unrelated suite.
- **A simulator wedged into "Application failed preflight checks"** needs
  `xcrun simctl shutdown all`. Killing `xcodebuild` mid-run is what puts it there.

---

## Prompt for a new chat

Paste this:

> Read `AIChatApp/HANDOFF.md` and `AIChatApp/README.md` in full before anything else. Both are
> verified working state, not guesses.
>
> Project: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/DevKnowledge/iOS Tasks/Portfolio Projects/AIChatApp`
>
> Task: fix the six failing UI tests. They assert a two-level navigation hierarchy (chat →
> destination) but the app now has three (list → chat → destination), so the back button they tap
> belongs to a different screen and the Diagnostics rows sit one push deeper. The app itself works
> — verify that on the simulator before changing any test, and do not "fix" a test by weakening
> what it asserts.
>
> Gates, all must pass before pushing:
> ```
> xcodegen generate
> xcodebuild -project AIChatApp.xcodeproj -scheme AIChatApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/aichatapp-coverage-dd -skipMacroValidation test
> swiftlint lint --strict
> SKIP_TEST_RUN=1 COVERAGE_THRESHOLD=0 ./Scripts/coverage.sh
> ```
> DerivedData must stay in `/tmp` (iCloud xattrs break codesign). Never commit `Secrets.xcconfig`.
>
> When the UI tests are green, report a full-suite coverage figure and update the README's status
> table with the numbers you actually measured.

To work on something else instead, swap the Task paragraph for one of the numbered items under
**What is left** and keep everything else.
