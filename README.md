# AI Chat

A SwiftUI iOS chat client for [OpenRouter](https://openrouter.ai), built on the 31-package Swift
LLM ecosystem from [`llm-ecosystem-demo`](https://github.com/rajatslakhina/llm-ecosystem-demo).

Every message runs through a real pipeline — prompt templating, PII guardrails, semantic routing,
caching, retrieval, compaction, cost forecasting, budget reservation, retries, streaming, tool
round-tripping, metering, settlement, answer screening, claim grounding and citation binding — and
**every refusal is surfaced to the user with the stage that caused it and the action that resolves
it**.

---

## Status

Measured on Swift 6.2.4 / Xcode 26.3 / macOS 26.5.2, iPhone 17 Pro simulator.

| Gate | Result |
|---|---|
| `xcodebuild build` | 0 errors, 0 warnings |
| Unit + integration tests | **835 passing in 145 suites**, 2 skipped (`LiveOpenRouterTests`, which need a real key) |
| UI tests (XCUITest) | **24 passing, 0 failing** — clean inside the full suite. On 2026-08-31 the flake was exercised three times in one session: `testDemoCredentialsReachTheChatScreen` failed once inside the full suite, then passed **7/7 in isolation** immediately afterwards, then passed inside a second full suite. One appearance in three full runs, and it is **still recorded as flaky rather than fixed**: two green full-suite runs do not retire a load-dependent failure that has come and gone across five sessions. Historically: 24 passing, 0 failing when the target is run on its own — and `testDemoCredentialsReachTheChatScreen` failed once again on 2026-08-27 inside the full suite, the third run in a row it has appeared. It is recorded as **still flaky rather than fixed**. 08-25 diagnosed it as load-dependent; 08-26 raised its wait from 15s to 20s to match every other reachability assertion in the file and called it green; 08-27 it timed out at 20s anyway, on a machine that had just built four packages and run the suite three times, then passed isolated with all 24 green in 268s. The wait is not the problem and raising it a third time would be a third guess. What is actually established: it is load-dependent, it is not caused by whatever change is in flight (verified isolated against the change each time), and the real fix is probably to stop the UI target inheriting a simulator that has just chewed through 750-odd unit tests. Earlier history: green since 2026-08-18, when a run of failures turned out not to be environmental at all but a real navigation regression in `ChatScaffold` — the thread was pushed by `.navigationDestination(item:)` while every other screen was registered on `.navigationDestination(for:)`, and that registration was not in scope from inside the pushed screen, so the Model, Diagnostics and Settings toolbar links rendered and did nothing. `profileButton` kept working because it lives on `ChatListView`, which carried the registration — which is what made the suite look chronically and inexplicably red. Fixed by unifying both onto one path-based registration. |
| `swiftlint --strict` | **0 violations**, 91 files |
| Line coverage | **94.14%** — 10932/11613, unit tests only, **clean DerivedData**, up from **94.09%** (10844/11525). The standing procedure is four things and all four matter: a **separate invocation** from the `xcodebuild` that wrote the bundle, `-enableCodeCoverage YES` passed explicitly, a DerivedData that has only ever seen the scope you are measuring, and — added 2026-08-28 — **run it twice and diff per file before believing a drop.** On 2026-09-02 that fourth rule earned its place for the first time. The first fresh-DerivedData unit-only run returned **92.74% (10684/11521)** — *lower* than the previous session, on a change that only added code — and the entire difference was `ModelPickerView.swift` at **43.85% (132/301)** against its healthy **95.35% (287/301)**. That is the two-state coin flip recorded on 08-28, in its bad state, worth 1.34 points on its own. A second independent run returned **94.08% (10839/11521)** with that file back at 95.35%, and the run after the last fix returned **94.09% (10844/11525)**. Had the rule not existed, the honest-looking move would have been to report a regression this change did not cause. It remains undiagnosed and the rule stays. The same tree measures **96.47% (11114/11521)** full-suite; the two modes differ by ~2.4 points because XCUITest is the only thing exercising `AppNavigation`, `ModelPickerView` and `ChatView`, so the mode has to match before numbers can be compared. On 2026-09-02's second run the fourth rule was applied as routine and both independent runs returned **94.14% (10932/11613)** with `ModelPickerView.swift` at its healthy 95.35% in both, so the coin flip stayed in its good state. `Sources/Core/Metadata/MetadataPipeline+SampleWidth.swift` added this change reads **100.00% (85/85)** after a dead branch was fixed rather than excluded; `Sources/Core/Metadata/MetadataPipeline+ProxyLabel.swift` holds at **100.00% (49/49)** and `Sources/Core/Pipeline/PanelHistoryStore.swift` holds at **100.00% (52/52)** after gaining the outcome half; `PipelineStage.swift` and `PipelineStage+Catalog.swift` read 100.00% (71/71 and 116/116); `MetadataPipeline+CurveDivergence.swift` still holds at 97.75% (87/89), a file-level accounting gap rather than an untested branch. |
| Verified against the live API | Yes — real answers, real token counts, real cost |

**All 53 packages do real work in the app.** 52 of them run in the send path and own a pipeline
stage; `EvalHarness` does both — it captures golden cases at runtime *and* gates regressions in
`Tests/`. See [Coverage](#coverage).

---

## Setup

```bash
brew install xcodegen swiftlint
cp Secrets.example.xcconfig Secrets.xcconfig   # then add your key
xcodegen generate
open AIChatApp.xcodeproj
```

Get a key at <https://openrouter.ai/keys>.

**`Secrets.xcconfig` is gitignored and must stay that way.** A key committed to a public repo is a
revoked key within minutes of GitHub's secret scanner reaching it — and drainable until then.

A fresh clone **without** `Secrets.xcconfig` still builds and launches (`Config/Base.xcconfig` uses
`#include?`, the optional form). The app starts with no key and routes the user to Settings rather
than crashing, so CI and other contributors are never blocked.

Key resolution order, all tested:

1. **Test harness** — `-OpenRouterAPIKey <value>` launch argument
2. **Keychain** — what the user last set on this device
3. **Build configuration** — `Secrets.xcconfig` → Info.plist, promoted into the Keychain on first launch
4. **Absent** — a legitimate state

An unexpanded `$(OPENROUTER_API_KEY)` reads as *absent*, never as a bearer token — otherwise a
missing key produces a 401 that looks like a bad key.

Demo login: `demo@aichat.app` / `letmein`. There is no backend; the screen says so.

### Commands

```bash
xcodebuild -project AIChatApp.xcodeproj -scheme AIChatApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

./Scripts/coverage.sh                  # per-file table; COVERAGE_THRESHOLD=100 to gate
swiftlint lint --strict

# Live API tests (spend real credit, opt in). Simulator tests do NOT inherit the host
# environment — the TEST_RUNNER_ prefix is required or they silently skip:
TEST_RUNNER_RUN_LIVE_OPENROUTER_TESTS=1 TEST_RUNNER_OPENROUTER_API_KEY=sk-or-v1-... \
  xcodebuild ... -only-testing:AIChatAppTests/LiveOpenRouterTests test
```

Always run `xcodegen generate` after adding a new file, or it is not in the target and you get
"cannot find X in scope" for code that plainly exists.

`Scripts/coverage.sh` puts DerivedData in `/tmp`. It must not live inside this repo — the project
sits in an iCloud-synced folder, and iCloud's extended attributes make codesign fail with
`resource fork, Finder information, or similar detritus not allowed`.

---

## Architecture

```
ChatViewModel (@MainActor)
      │
      ├─ PreModelPipeline (actor) ──── 8 stages, all free
      │     template → guardrail(in) → route → cache → memory
      │     → retrieval (dense ∥ lexical → rank fusion) → compaction
      │
      ├─ TurnExecutor (actor) ───────── everything that costs money
      │     profile → forecast → reserve → idempotency → retry → route → stream
      │     → tool round trip → session → meter → settle
      │        └─ ToolRoundTrip: authorize (ToolAuthorityKit) → dispatch (ToolRegistryKit)
      │                          → observation (AgentLoopKit) → re-stream, max 3 hops
      │
      ├─ PostModelPipeline (actor) ──── judging an answer already paid for
      │     guardrail(out) → grounding → tracing
      │
      └─ MetadataPipeline (actor) ───── after the turn, off the critical path
            transcript capture → batch(title ∥ follow-ups) → decode → repair → migrate
```

The split is at the point the turn stops being free. Everything before `TurnExecutor` is local
computation; everything inside it either costs money or exists to control what it costs.

Screens: login → **chat list** → chat → model picker, settings, diagnostics; profile and edit
profile from the list.

Each conversation picks its own model **and** its own reasoning effort — Low, Medium, High, Extra,
fastest to smartest. Effort is not an app-invented dial: it is sent as OpenRouter's own
`reasoning.effort`, which allocates roughly 20 / 50 / 80 / 95 percent of `max_tokens` to thinking
(`extra` is `xhigh` on the wire). A conversation that never chose one sends no `reasoning` key at
all rather than a null.

Times read "Now", then seconds, minutes and hours ago; once a day has passed the row shows a
clock time instead, because the day heading above it already says which day. The list is grouped
into Today, Yesterday, and then `Month D, YYYY`. Days are compared as calendar days rather than as
24-hour windows — something sent at 11pm is "Yesterday" at 1am, two hours later. Every string is
rendered through `Calendar.current`, so a timestamp written by a server in UTC displays in the
device's own zone; a `Date` carries no zone of its own, so that rendering *is* the conversion.

Under every message: copy, edit, retry, read aloud, more. Edit and retry only on the user's own
messages, because retrying an answer means resending the question above it. "More" holds what used
to sit permanently under the bubble — sources, grounding, model, tokens, cost, attempts — plus the
time. Those chips truncated to a row of ellipses at any real width, and an unreadable number costs
the same space as a readable one while telling nobody anything.

Profiles are local and switchable. There is no backend, so a "user" is scope rather than an
identity: each profile owns its own conversations (`conversations.v1.<uuid>`) and its own settings
(`settings.v1.<uuid>`), and the pre-profile `settings.v1` blob is inherited once so an existing
install does not silently reset. Chats persist; a `ChatBubble` does not — delivery state, tool
chips and refusals describe one run of a turn, and restoring them would show a spinner for a turn
nobody is awaiting.

### Ordering decisions that are load-bearing

- **Template before guardrail** — the guardrail screens the *rendered* text. Screen the template
  instead and PII hides behind a variable.
- **Route before cache** — the cache key includes the model, so a cheap model's answer is never
  served as if the expensive one produced it.
- **Retrieval before compaction** — retrieved passages sit inside the same token budget as the
  conversation. The other order lets retrieval push it over the window and get silently truncated.
- **Authorize before dispatch** — a denied tool call never reaches the registry. Asserted by
  `statistics.totalCalls == 0`, not assumed.
- **Review before display** — a redaction changes what the user sees, not only what a log records.
  Only the *reviewed* text is cached, or the next identical question serves the un-redacted answer.

### Refusals

`StageOutcome.refused` is a separate case from `.failed`. A refusal is the system working — a
budget saying no, a guardrail redacting, an authority check declining. A failure is the system
breaking. Collapsing them is how a product ends up saying "something went wrong" when the truthful
answer was "you're out of budget": the first is unactionable, the second isn't.

Every `Refusal` carries `headline`, `explanation`, and a `recovery` action. A test asserts **every**
recovery action produces a usable button title, so a refusal cannot reach the UI as a dead end.

### Tool approval

`Settings ▸ Ask before running tools` issues every capability with `requiresApproval`, so the
broker answers `.approvalRequired` rather than allowing the call. The turn stops, the refusal
banner offers **Approve <tool>**, and the sheet shows the tool, the resource, the arguments in
full, and — leading, when it applies — that the arguments came from retrieved content rather than
from the model. That last line is the whole point: a prompt saying only "allow tool call?" gets
tapped through, and the case worth catching survives that habit.

Three properties are load-bearing, and each has a test:

- **A signature binds to a digest, not to a tool.** `ProposalDigest` excludes the proposal id, so
  the resend — a fresh proposal of the same call — satisfies the signature, while *different
  arguments* do not. Approving `calculator` once does not approve `calculator` forever.
- **A signature is spent once.** The broker throws `approvalAlreadyUsed` on a second presentation,
  and the gate maps a throw to `.failed`. So the app takes the signature out of its own map as it
  uses it: asking the same question twice is an ordinary second request, not a broken system.
- **Toggling the requirement re-issues every grant.** Capabilities are frozen into a `Grant` when
  it is issued, so flipping the switch without revoking would run the conversation under the policy
  the user just changed away from. Signatures are dropped at the same time, or an off/on round trip
  would silently re-arm one.

---

## What was learned the hard way

**An interval clamped to `-1...1` is not clamped to anything this table could produce.**
(2026-09-02) `effectiveVote` publishes a confidence interval for every pair of gates, built by
`EffectiveVoteKit`'s Fisher transform and clamped to `-1...1`. That is the bound on *any*
correlation. It is not the bound on one those two gates could have shown. Fix a pair's row and
column totals and phi becomes linear in a single cell, so the attainable range closes in hard the
moment the totals are lopsided — and in a chat client they always are, because gates fire on a small
minority of turns. The published intervals were quoting values no arrangement of the observed turns
produces. The new `sampleWidth` stage checks each one against `MarginFeasibleRange` and names the
overreach. Nothing about the Fisher transform is wrong; it was answering a question about
correlations in general when it was asked about these turns.

**"Not enough data" is a number, and refusing to compute it is a choice.** (2026-09-02)
`effectiveVote`'s refusal path has always named the figure it was withholding and never named how
many turns would let it publish. A reader could tell that the panel was thin and could not tell
whether waiting was worth it. `SampleSufficiency.requiredCount` inverts the interval's own width and
answers in turns. On an install that has observed nothing, the stage still quotes the count, because
that is the one actionable thing available before any gate has fired twice — and the count is
larger than anyone guesses.

**A stage that reports five rows where six pairs exist has hidden the interesting one.**
(2026-09-02) The first draft of the umbrella demo's matching scenario used `try?` and a `continue`
around the per-pair interval, and quietly dropped `answerability x morphology` — the one pair whose
phi is exactly 1.0000, where the Fisher transform is unbounded. Five confident readings and no sign
that a sixth existed. The same shape was in the app stage's first draft. Both now print the refusal.
**A gap that looks like an absence is worse than a refusal that looks like a problem.**

**Two independent fresh-DerivedData coverage runs, and this time they disagreed.** (2026-09-02)
The twice-and-diff rule has been in this file since 08-28 and had never once changed an answer. It
did here. The first unit-only run on a clean DerivedData came back at **92.74%**, below the previous
session's 94.06%, on a change that added code and deleted none. The whole gap was
`ModelPickerView.swift` at **43.85%** instead of its usual **95.35%** — 167 lines, 1.34 points, and
nothing to do with the change in flight. The second run returned 94.08% with that file healthy. A
procedure that only ever confirms what you already believe is indistinguishable from no procedure
until the day it does not, and the cost of not having it here would have been reporting a regression
that did not exist.

**A downstream outcome is evidence about the turn, not about a judge, and that is not a detail.**
(2026-09-02) `checkConsistency` already decides per turn whether an answer contradicted its own
sources, so deriving a correctness label for every gate that admitted the evidence is one line of
code. Using it is the hard part. One outcome labels all four gates at once, so any error in it is
shared by every one of them, and shared label noise does not blur an error correlation toward zero
the way independent noise does — it manufactures one. The new `proxyLabel` stage therefore derives
the labels, names the regime, and reports the exact refusal that stops `effectiveVote` switching
basis, rather than switching it. The tempting version of this change would have looked like an
improvement and would have invented dependence between gates that share nothing.

**The turn id had to travel in the trace, and there was already a precedent for it.** (2026-09-02)
The gates are recorded before the model and the outcome arrives after it, and the only thing tying
the two to the same turn is an id. Attaching an outcome to "whatever the store saw last" is correct
right up until two turns overlap. `PipelineTrace.explorationID` had solved exactly this problem
before, for exactly this reason, so `panelTurnID` follows it rather than inventing a second
mechanism. Reading the file for prior art was faster than the plumbing would have been.

**A stage that runs after an early return does not run on the path that takes it.** (2026-09-01)
`MetadataPipeline.generate` bails out before every audit stage when the turn produced no answer
text, recording four stages as skipped and leaving the five audit stages beside them `unreached`.
The new `effectiveVote` stage audits gate readings accumulated over *earlier* turns and has nothing
to do with this turn's answer, so placing it with its siblings would have made it silently absent on
exactly the path a reader is most likely to be investigating. It runs before the guard instead. The
general version: "record on every path" is a claim about control flow, not about where the call
reads well, and `PipelineTrace.unreached` is the only thing that makes the difference visible.

**The stage-table test cannot tell you a stage executes.** (2026-09-01)
`coversEveryPackage` asserts the `PipelineStage` table names every package in the series, and it
fails until a new case is added — which is a useful reminder and is easy to mistake for proof of
wiring. It passed the moment the enum case existed, while `MetadataPipeline+EffectiveVote.swift`
sat at **43.75%** line coverage and the stage had never been executed by anything. Coverage caught
it; the table test could not have. A new stage needs a test that drives the stage.

**A fifth judge widens the interval more than a fifth data point narrows it.** (2026-09-01)
The effective-vote test that adds a constant gate to the panel failed at 60 observed turns and
passed at 200, and neither number was arbitrary: the design effect divides by `1 + (k-1)·rho`, so
adding a judge multiplies the spread the confidence interval has to cover while each extra turn only
shrinks the standard error by `1/sqrt(n-3)`. The test was not flaky and the policy was not wrong —
a five-gate panel genuinely needs more evidence than a four-gate one before anything should be
published about it.

**A single field answering two questions is cheaper to find than to believe.** (2026-09-01)
`SelectionTrustGate` decides whether a tool argument came out of a retrieved passage with case-folded
substring containment, skipping anything under four characters — a rule whose own doc comment calls it
the weak half of that stage. Pointing `ArgumentAttributionKit` at the same arguments showed the rule
fails in **both** directions on this app's own fixtures, and the two failures are opposite: `4200`
against a passage that spells the number out is **missed entirely**, while `days` against "within 5
working days" is **counted as evidence** at 3.22 bits, which is roughly the evidentiary weight of a
coin landing three times. A matcher that can be wrong in both directions cannot be made safe by tightening
it in one, and the only way to see that was to run a second matcher beside it and print where they
disagree. The new stage does not replace the old one — it audits it, on every call, in the trace.

**A package's own test suite cannot find the API hole that only a consumer falls into.** (2026-08-31)
`SelectionTrustKit` shipped at 1.0.0 with 100% line coverage, 86 passing tests and a
`ConfirmationPresenter` protocol that a consuming app is expected to implement. This app implemented
one, and then could not write a test for it: the presenter is handed a `ConfirmationRequest` whose
memberwise initialiser was internal, so nothing outside that module could construct the value its
own presenter receives. `RefusalReason` had the same hole. Neither was a decision — both were the
default access level going unexamined — and **no test inside the package could have caught either,
because every test in it lives inside the module where the initialiser is visible.** Coverage proves
you executed your code; it says nothing about whether the code is reachable from where it is meant
to be used. Fixed in 1.0.1, found within minutes of the first real consumer.

**The over-tainting was invisible because nothing ever measured it.** (2026-08-31)
`ToolCallContext.forTurn` stamps every tool argument `.untrusted(source:)` the moment the turn
carried any retrieved passage, without asking whether the argument bytes came from one. That is safe
and it is coarse, and with `maxProvenance: .modelAuthored` on every capability it means one
retrieved passage denies a calculator call whose arguments appear nowhere in that passage. The
denial looks identical to a correct one from the outside — same stage, same refusal, same banner —
so there was no symptom to notice. It took a stage whose only job is to separate the two questions
to produce the number, and the number is per-call rather than global: some calls are correctly
tainted and some are not.

**Two remedies bundled into one refusal look like one problem with no remedy.** (2026-08-31) Four
delay stages in a row — `delaySignal`, `delayShape`, `delayCurve`, `curveDivergence` — each declined
for a reason of its own, and each reason ended in the same sentence: this app records *whether a
verdict arrived* and *what it said* in one field. Written out four times in four doc comments, that
reads as a single wall. It is two walls with different heights. The **cohort** half has a remedy
available today: `admissionProbability` is fixed when the turn is admitted, and swapping the cohort
onto it turns `0 of 10 admissions censorable` into `3 of 10` on the same entries — measured, in
`labelClock`, not argued. The **clock** half does not: every admission is timestamped `admitted 0,
returned 1`, so follow-up is one tick wide whatever the cohort is. Stating them together hid that
one of them was cheap. A stage that measures a shared premise is worth more than a fifth stage that
restates it.

**A recovered number is not a green light, and has to say so in the same breath.** (2026-08-31) The
admission-time cohort this app owns is *whether the turn was explored* — and an explored turn is
bought precisely to obtain a label, so its labelling rate differs from the other arm's by
construction. Recovering the censoring makes the **schema** right without making the **comparison**
valid. `clockRemainder` prints both sentences and a test pins both, because a detail string that
reported the first number alone would read as a stage handing something on.

**The `ModelPickerView` coverage flake reproduces to the digit.** (2026-08-31) 08-28 recorded it as
non-deterministic. Today it came back at **43.85% (132/301)** — the same figure, not a nearby one —
and returned to **95.35% (287/301)** on the next identical run, moving the total 1.38 points. Two
outcomes, both exact, is a coin flip between two states rather than noise, which is a different and
more findable bug than "flaky". Still undiagnosed; recorded so the next run does not re-derive it.

**A single low coverage reading is not a regression until it reproduces.** (2026-08-28) The first
clean unit-only measurement of the `curveDivergence` change came back at **92.41%**, 1.4 points below
the recorded 93.81%. Every documented precaution had been taken: separate invocation, explicit
`-enableCodeCoverage YES`, a DerivedData directory created fresh for that one scope. The parent
commit, checked out fresh and measured the same way, returned **93.81%** exactly — so the procedure
was sound and the deficit looked real. It was not. The entire 1.4 points was `ModelPickerView.swift`
reading **43.85% (132/301)** instead of its usual **95.35% (287/301)**, and an identical rerun in
another fresh DerivedData put it back. That file is 301 lines, so on its own it moves the total by
more than a point. **`ModelPickerView.swift`'s coverage is non-deterministic between runs** — a
distinct trap from the DerivedData-scope one below, and one that mimics a regression just as
convincingly. Measure twice before believing a drop, and diff per-file rather than reading the total.

**A package's own test suite cannot catch a wrong premise.** (2026-08-28) `CurveDivergenceKit` 1.0.0
shipped with a refusal that declined whenever one arm had no label inside the shared window. It had
tests, they passed, and they agreed with it — because the same person wrote the refusal and the
tests, on the same wrong reasoning. It took running the package against a real panel in
`llm-ecosystem-demo` for the refusal to fire on that project's strongest result and expose the error:
an arm that has resolved nothing has a curve flat at one, and a flat line against a fallen curve is
the *largest* separation two survival curves can show. Fixed in 1.0.1. The lesson is about where
that class of bug is findable, not about survival analysis.


**One `-derivedDataPath` reused across different `-only-testing` scopes gives a coverage figure
that is wrong and looks plausible.** This run measured 92.39% unit-only and spent an hour treating
it as a regression against a recorded 93.77%. It was not a regression and it was not the missing
`-enableCodeCoverage YES` flag this README already warns about — that flag was passed. The bundle
had simply been written into a DerivedData that had already served a `-only-testing:AIChatAppUITests`
run, a full run, and two unit-only runs, and `Scripts/coverage.sh` takes the newest `.xcresult` under
it without knowing which scope produced which. The same tree in a **clean** DerivedData measures
**93.81%**, and the parent commit measured the same way returns **93.77%** — the recorded figure
exactly. So the honest procedure is now three things rather than two: separate invocation, explicit
`-enableCodeCoverage YES`, **and a DerivedData that has only ever seen the scope you are measuring**.
`DERIVED_DATA=/tmp/aichatapp-dd-$(date +%s) ./Scripts/coverage.sh` costs one clean build and removes
the whole class of error. What made this expensive was that the wrong number was *close* — 1.4 points
low, in the right ballpark, moving in the direction a real regression would move.



**A package that can compute where its siblings cannot is not thereby the one to trust.**
`delaySignal` needs two separable rates and `delayShape` needs one of four families to fit; both
decline on this app's ledger and say why. A product-limit estimate needs neither, so `delayCurve`
produces a perfectly well-formed curve here — and it is wrong in a way nothing in the data reveals.
Every label and every cutoff land in the same tick, so the estimator finds an event at its support
limit and reports the distribution **complete**, claiming everything resolved by t1 while a share
of the admissions never resolved at all. The assumption it breaks is non-informative censoring: an
unlabelled admission here is a turn that never reached a verdict, not a slow one. The stage skips
with that spelled out rather than shortened, because the short version is the sentence `delayShape`
already prints, and because *being able to produce a number* and *being entitled to it* came apart
here in the only direction that matters.


**Clear the whole DerivedData tree or none of it — half a tree fails as a toolchain error.** Twice
on 2026-08-26 a build died with `fatal error: module file '.../ExplicitPrecompiledModules/
_DarwinFoundation3-*.pcm' not found`, which reads like a broken Xcode install and is not. `/tmp` had
been swept, leaving SwiftPM's checkout directories present but empty; clearing just
`SourcePackages/` fixed the resolution error and left `Build/Intermediates.noindex` behind, still
pointing at precompiled modules that no longer existed. Delete the entire `-derivedDataPath` and
build again. The first error names packages, the second names the SDK, and they are the same fault
one step apart.


**Wiring a package into this app is the cheapest bug-finder the packages have.** `DelayShapeKit`
shipped at 1.0.0 able to fit a delay distribution and rank four candidate shapes. Pointed at this
app's ledger — where every label arrives exactly one tick after its admission — all four families
scored a log-likelihood of **exactly 0.000**, because under the truncated likelihood a single-valued
delay has probability one under any shape. AIC then separated them on parameter count alone and the
exponential "won" with `rate 0.1000`, which is the untouched midpoint of the search bounds. The
package handed that back as a fitted shape, with the verdict that reads as *the incumbent held* —
a positive finding. Nothing in its own 78-test suite caught it, because every fixture there had a
delay distribution in it. 1.0.1 added `minimumDistinctDelays` and refuses. The lesson is not about
that package: **a library's test suite is written by someone who knows what the input is supposed to
look like, and an app is not.**

**Two gates that look like one, and the order between them is the whole content.** Too few labels
and labels that are all the same are different failures with different remedies, and merging them
sends an operator to fix the wrong thing — told "insufficient evidence", they wait for traffic that
cannot help. But the check runs volume-first anyway, because three returns that happen to share a
tick really is just a small sample. Only once you have enough of them does sameness mean anything.


**A package can be wired in correctly and still have nothing to do here, and that is a result rather
than a failure.** `delaySignal` reads how long each verification took, to find out whether the labels
`labelReturn` is waiting on are late or gone. This app verifies **inline** — an exploration is
admitted in `PreModelPipeline` and labelled in `PostModelPipeline` of the same turn — so every delay
it can generate is the same number, the identifiability condition cannot be met at any sample size,
and the stage skips with that measured. The useful half is the second sentence of the skip: the
admissions still unlabelled here are **not a queue**. They are turns that never reached a verdict, and
a reader who takes them for a backlog will wait for labels nobody is sending. Recording the measured
skip took about as long as a token call would have and says something true.

**An arm that only an array can reach needs a function that takes an array.** The audit's
"ledger could not be read" arm cannot fire through an `ExplorationLedger`: that actor keys entries by
id and carries a validated probability, so neither thing the audit throws on can occur. The previous
run's answer to the same shape was to collapse the guard. Collapsing was wrong here, because the arm
is real — `ExplorationReturnAudit` takes a plain array, and an array can hold a duplicate id. Adding
an entry-list overload made the arm reachable from a test instead of unreachable in the send path,
which is the difference between a branch that is covered and one that is merely reported as covered.

**Coverage is a measurement of your instrument first.** Two numbers moved this run before any code
did: a full-suite run reports higher than a unit-only run because XCUITest exercises the view layer,
and a bundle written without `-enableCodeCoverage YES` reports lower off partial data. Comparing
across either difference produces a "regression" that is entirely an artefact of how it was taken.
The baseline and the new figure have to come from the same command, and this run took both.

**A whole test target failing is evidence of a big bug, not of a broken environment.** For four runs
this README recorded the XCUITest target as down "in its entirety" and reasoned from the breadth of
it: classes that could not reach the changed code were failing too, so the cause had to be
environmental. That inference is backwards. Breadth is what a bug in shared navigation *looks* like
— every screen reached through the chat toolbar was unreachable, which is most of the suite. The
suite was reporting a real regression accurately for four runs while the summary called it noise.
The tell was available the whole time and was never looked at: `ScaffoldUITests` passed throughout,
and it is the only class that navigates from the list rather than from inside a thread.

**"Not confirmed against a clean clone this run" is where it went wrong.** An earlier entry in this
very section says a UI failure is not pre-existing until you have run it without your change, and
that it costs about two minutes. The next four runs quoted the *previous* run's confirmation instead
of performing one. A verification that is inherited rather than repeated is a claim about history,
not about the code in front of you.

**Reordering two modifiers was the wrong first fix, and running it was still worth it.** The
hypothesis was that `.navigationDestination(for:)` had to be declared before
`.navigationDestination(item:)`. Swapping them changed nothing — the test failed identically — which
refuted order-dependence and pointed at the mixing itself. Unifying both onto one path-based
registration then passed. Two experiments, one refuted and one confirmed, is the difference between
knowing the cause and having a fix that happens to work.

**A stage that loosens a gate is safest when the ordering makes it impossible to loosen the wrong
one.** `explorationChannel` is the only stage here that overrides a refusal the certificate
genuinely supports, and the first instinct was to write a rule — *only explore conformal refusals*
— and trust it. The rule is there, but it is not what makes the stage safe. Every judging gate and
the arbiter `return` before this stage runs, so their refusals cannot reach it at all. The guard is
a second line against a future edit reordering the pipeline; the ordering is the actual guarantee.
A constraint the type system or the control flow enforces survives a refactor that a documented
rule does not.

**An unreachable branch is sometimes a misread branch.** The stage's declining switch came back
with two uncovered lines on the `.notRefused` arm, which the caller's own guard makes impossible —
the seventh run in a row to turn up dead code behind a line that looked covered. The reflex by now
is to delete it. Reading it again first was worth more: `.notRefused` is reached when the gate
refuses a turn whose score sits *inside* the certified threshold, which is not an impossible state
but the refusal and the score disagreeing. It is now a `.skipped` that names the disagreement, and
a test produces it. Deleting it would have removed a real diagnostic to satisfy a coverage number.

**Exploration buys a chance, not a label.** `recordExploredTurn` logs the turn as `.censored` with
admission probability `omega` rather than waiting for an outcome, and that ordering is deliberate:
the answer has not been produced yet, let alone verified. What changed at the moment of admission
is that the turn *had a chance*, and that single fact is what gives its region a finite
inverse-probability weight. `CensoringFeedback.refused` logs zero and nothing can ever be
reweighted from it. The label may arrive later or never; the chance is the part worth recording
immediately.

**A label that is never routed back is spend with no evidence, and the comment saying otherwise
was half true.** `recordExploredTurn` has always ended with "the label arrives later or not at
all", and until this change it was never *at all*: every exploration this app paid for sat in the
channel's ledger as an admission with no outcome attached, because the only place the verdict
exists is the far end of the turn and nothing carried it back. `labelReturn` closes it. The id
travels on `PipelineTrace` as a typed field rather than in a `detail` string, because the stage
that admits and the stage that learns the verdict are at opposite ends of the pipeline and
recovering an id by parsing prose is how a label ends up on the wrong admission.

**A recorded coverage figure is not a baseline until it reproduces.** This table said 93.96% and
the honest comparison for a new change is against that number — except a like-for-like run of the
same commit reports 93.64%, on an identical denominator. Thirty-four lines' difference on
unchanged code. So the number to beat was measured rather than read: a `git worktree` at the parent
commit, the same command, the same machine, the same hour. The lesson is the one this file keeps
relearning from a different direction — **a figure carried forward in prose is a claim, and the
cheapest way to find out whether it is a measurement is to take it again.**

**`-enableCodeCoverage YES` is not implied by the coverage script.** `Scripts/coverage.sh` with
`SKIP_TEST_RUN=1` reads whatever result bundle is newest, and a plain `xcodebuild test` writes one
without full coverage instrumentation. That bundle does not fail — it reports a *lower* number off
partial data, which reads exactly like a regression. Two readings this run (92.25%, then 93.67%)
were that, and neither was real. Pass the flag on the run that writes the bundle you intend to
measure.

**The app still cannot tell a user their answer was an exploration.** When the channel admits a
turn, the user receives an answer the app had decided not to give, and nothing on screen says so.
This app's only channel for that kind of statement is a `Refusal`, and inventing a second one
inside a pipeline stage would be a UI decision made in the wrong place. The admission is in the
`PipelineTrace` and on the Diagnostics screen, which is an audit trail and not a disclosure. Naming
the gap is worth more than quietly leaving it.

**A gate that lets everything through because it is uncalibrated looks exactly like a gate that
examined the turn and approved it.** The conformal gate's ordinary outcome for this app's first
eighteen answered turns is `.noOp`, and it names the shortfall — `12 calibration points cannot
certify alpha 0.050; 19 are needed` — rather than recording something that reads like an approval.
The distinction only exists because `StageOutcome` has both `.ran` and `.noOp`; collapsing them
would have hidden a stage that cannot do its job behind one that had nothing to do.

**The app can only ever label the turns it answered.** A turn the gates refuse is never sent, never
verified, and never labelled, so the calibration set is drawn from traffic that got through rather
than from all traffic. The conformal guarantee is honest about the population it was calibrated on
— and that population is not the one the gate meets. This was stated in `ConformalLedger` rather
than fixed for one change, and **`censoredFeedback` now closes it**: every refused turn that
anything scored is recorded too, and the audit decides whether the certificate's promise reaches
the traffic the gate actually sees. What could not be fixed is the part that needs a feedback
channel — the app still cannot learn what a refused turn *would* have done. The difference is that
the gap is now measured and priced rather than described.

**A refusal that rests on nothing is harder to notice than a gate that is switched off.**
`censoredFeedback` is the only stage in this pipeline whose effect is to stop a gate refusing, and
that direction deserves suspicion: a stage that loosens gates is a lever somebody will reach for.
It is bounded to one gate — the conformal one, whose entire claim is a numerical guarantee — and it
withdraws enforcement only when the arithmetic shows that guarantee was computed over a population
this app does not meet. It cannot touch the four judging gates, and it produces no refusal of its
own.

**A stage that costs nothing to add still has to be recorded on every path.** `censoredFeedback`
runs between the arbiter and the conformal gate, so both early-refusal paths in
`refusalBeforeSending` had to learn to record it as `.skipped` — the same six lines the conformal
gate already needed one change earlier. A stage missing from the trace on some paths is a stage the
Diagnostics reader cannot tell apart from one that silently did not run.

**A stage whose score is computed from other stages' readings must not file a reading of its own.**
The conformal gate's nonconformity score is derived from the four gates' reservations. Filing a
reservation would put their opinion in front of the arbiter twice — exactly the entanglement
`signalDependence` runs immediately upstream to catch. It refuses on its own authority or says
nothing.


- **`xcodegen generate` must run after adding a *test* file, not only a source file.** On 08-19 a
  new stage source file was added, `project.yml` was edited, `xcodegen` was run — and the stage's
  test file was written afterwards. The build succeeded, every test passed, and the run reported
  **681 tests in 124 suites: exactly the previous run's count.** Nothing failed, nothing warned,
  and the new suite simply was not in the target. The tell is a test count that does not move when
  you have just added tests, and it is worth checking for by name (`grep "Suite \"<new suite>\""`)
  rather than by trusting a green run. A passing suite you never compiled is indistinguishable
  from a passing suite you did.

- **A finding a stage will not stand behind must not be able to corroborate another one.**
  `AbstentionPolicyKit` abstains when two distinct gates each raise a concern. Wiring it, the
  answerability gate's untrusted coverage gap and the stability pass's thin-support number were
  both filed as concerns — and together they refused *"how much am I spending, what is the
  ceiling"*, the same query this app has now wrongly refused three times by three different
  mechanisms. `HybridRetrievalTests` caught it, and has now been right four times running. Both
  readings are ones the owning stage explicitly discounts: absence on an unkeyed attribute aspect
  is a claim about spelling, and offsetting weakness is a statement about a *conflict* that does
  not bear on a ruling nobody contested. They are not two independent judges — they are two
  symptoms of one recall gap. Both now file `.unavailable`, which is what the four-case vocabulary
  is for: **"I ran and could not rule" is not "I found something mild."** Concurrence only means
  anything if the concurring voices are independent, which is `SourceIndependenceKit`'s lesson
  arriving one layer up.

- **Read a result bundle in a different command from the one that wrote it.**
  `Scripts/coverage.sh` reported 91.95% immediately after the `xcodebuild` run that produced the
  bundle, and 93.51% from the identical bundle a moment later. Chaining the two in one shell
  command reads a bundle Xcode has not finished writing, and the number it gives is quietly wrong
  rather than an error. Anything derived from an `.xcresult` should be a separate invocation.

- **Reproduce the baseline before believing a coverage regression.**
  This change looked like it dropped coverage from a README figure recorded on a previous run. A
  fresh `git clone` of the previous commit, a clean DerivedData and a unit-only run returned
  9496/10166 — the recorded figure exactly. That takes four minutes and converts "the number
  moved" into "the number moved *because of this change*", which are different claims. The same
  clone then settled the UI failures as pre-existing without touching the working tree, which a
  `git stash` would have.

- **A pure stage on an actor should be `nonisolated`, and the tests will tell you.**
  `establishSourceIndependence` reads one immutable `Sendable` analyzer and pure statics, but it
  was first written as an ordinary member of the `PreModelPipeline` actor. Every test failed to
  compile with *actor-isolated instance method cannot be called from outside the actor* — and
  `await` does not fix it, because the stage takes `trace` as `inout` and exclusive access cannot
  cross an actor boundary. Marking it `nonisolated` compiled immediately and is also the honest
  description of what it does. If a stage needs no isolation, saying so costs nothing; discovering
  it through a wall of test errors costs an hour.

- **Adding a `PipelineStage` case means three edits, not two, and the count is the decoy.**
  `PipelineTraceTests` asserts both `expected.count == N` *and* set equality against a literal list
  of package names. Bumping only the count makes the count assertion pass and the equality
  assertion fail with `missing: [...]`. The docstring and the `@Test` title carry the number too.
  Case, `stage.package` mapping, the set literal, the count, the docstring and the test title —
  all six move together.

  **2026-08-17: it is seven, not six.** `PipelineStage` has a *second* exhaustive switch —
  `title`, which the Diagnostics screen renders — and it sits far enough below `package` that
  updating one and not the other is the natural mistake. The compiler does catch it, but as
  `Switch must be exhaustive` inside a 60-line `xcodebuild` failure dump rather than next to the
  case you just added. The language server flagged it immediately and it was scrolled past. When
  a tool tells you a switch is not exhaustive, that is the cheapest this finding will ever be.

- **A UI failure is not pre-existing until you have run it without your change.** This run's suite
  came back with one failure, in a Diagnostics *navigation* assertion with nothing to do with the
  pipeline, and this README already records the suite as chronically red. Both facts point at
  "pre-existing" and neither establishes it. `git stash push -u`, a clean DerivedData and
  `-only-testing:AIChatAppUITests/DiagnosticsUITests` settled it in one run: it fails identically
  without the change. That is the difference between reporting a verified result and a plausible
  one, and it costs about two minutes.

- **A coincidence finding only bears on the ruling it is about.** `EvidenceSensitivityKit` reports
  `offsettingWeakness` when two sides land close while neither is independently strong. Wiring that
  straight through to a refusal blocked *"how much am I spending, what is the ceiling"* against this
  app's own budget corpus — because that turn was ruled **answerable**, not contested, and for an
  answerable ruling the same two numbers mean only that support was thin. There was no conflict
  claim for the finding to undermine. The stage now refuses only when the gate itself ruled
  `contested`, and records otherwise. This is the third time a wholesale refusal in the pre-model
  gates has been wrong, and the third time for a different reason than the last — and the same
  `HybridRetrievalTests` caught all three.

- **A package's own demo shares the blind spots of whoever wrote it.** The same wiring exposed a
  real bug *inside* `EvidenceSensitivityKit`: `offsettingWeakness` never checked that there were
  two sides, so affirming 0.15 against denying 0.00 — a margin of 0.15, inside any conflict margin
  — was reported as two failures cancelling. Nothing had cancelled; there was no second side.
  Every scenario in that package's nine-scenario demo happened to give one side a score of 0.4 or
  better, so its own tests could not have found it. Fixed in `1.0.1`. The first real consumer is
  worth more than another scenario written by the same hand.

- **The app cannot tell two chunks of a page from two pages.** `RetrievedSource` carries `id`,
  `title` and `snippet` — no document identifier. `verdictStability` uses `title` as a stand-in, so
  two same-titled documents merge into one. That under-reports independence and never over-reports
  it, which is the safe direction: it can route a sound answer to review, and cannot let a
  single-source answer pass as corroborated. A real document identifier belongs in the retrieval
  layer and is not yet there.

- **Improving recall on one side of a disagreement can hide the disagreement.** Swapping in
  `MorphologyMatchKit`'s matcher turned a refusal into an admission on this app's own retry corpus,
  and the mechanism took a while to see. `AnswerabilityKit` calls an aspect contested when the
  affirming and denying strengths land within `conflictMargin` (0.2) of each other. Under the
  lexical matcher both sides scored **0.75** — one passage was missing `retry`, the other missing
  `times` — so two *different* recall failures cancelled out and the contradiction was caught by
  luck. Keying lifted the affirming side to **1.00** and left the denying side at 0.75: 0.25 apart,
  outside the margin, verdict `.answerable`. The fix was not to widen the margin but to stop
  reading symmetry at all — this app now refuses on the *presence* of two-sided support, which no
  strength change can hide. A threshold that happens to pass is not the same as a property that
  holds.
- **A branch that stops being reachable is a test that stopped running, and coverage is how you
  find out.** The same keying change made `AnswerabilityKit`'s own `.contested` verdict unreachable
  from the test suite — every contested corpus now routed through the app's two-sided check
  instead — and it showed up as exactly one uncovered line. The fix was a second test with a
  *symmetric* corpus, so both paths to the same refusal are exercised.

- **A refusal based on absence is only as good as your matcher's recall; one based on presence is
  not.** `answerabilityGate` was first wired to refuse on `AnswerabilityKit`'s `.insufficient`
  verdict — the claim that *nothing* in the corpus speaks to some part of the question. That
  blocked "how much am I spending" against this app's own budget corpus: the corpus says `spend`
  and `spends`, the question says `spending`, and `LexicalEvidenceMatcher` does no stemming. Three
  existing `HybridRetrievalTests` caught it. `.contested` has no such exposure — it needs two
  passages that both matched and point opposite ways, so a recall gap can only make it fire *less*.
  The app refuses on `.contested` and records the coverage gap into the trace instead. The gap
  closes when the matcher does; `EvidenceMatching` is a protocol for exactly that reason.

- **The same judgement in two places means only one of them is tested.** The answerability stage
  opened with its own `guard !sources.isEmpty` before calling a package that already reports
  `.undetermined(.noEvidenceOffered)`. That made the package's arm unreachable, and coverage found
  it as one dead line at 98.61%. Deleting the guard and letting the verdict drive both trace
  outcomes took the file to 100.00% by removing code, not by adding a test.

- **A branch no test can reach is a branch whose behaviour is a guess, and coverage is how that
  shows up.** `claimDecontextualization` handles two inputs a real `GroundingReport` never
  produces — an empty claim list and a blank claim — and both were unreachable through a send, so
  the file sat at 88.04% and the repo total fell *below* its own baseline. The fix was not a test
  that pokes at privates: an internal `checkDecontextualization(claims:against:trace:)` overload
  makes the malformed-input contract callable, the send path uses the single-argument form, and the
  doc comment says which is which. Repo went 92.92% -> 93.07% and the file to 100.00%.

- **`/tmp/aichatapp-coverage-dd` can rot, and the error blames the packages.** A run failed with
  `Could not resolve package dependencies: .../workload-profiler-kit/Package.swift doesn't exist`
  for six packages at once. Nothing was wrong with any of them — the tmp reaper had eaten parts of
  `SourcePackages/checkouts`. `Scripts/coverage.sh` honours `DERIVED_DATA`, so a fresh path fixes it
  without deleting anything: `DERIVED_DATA=/tmp/aichatapp-dd-$(date +%m%d) ./Scripts/coverage.sh`.

- **Compare unit-only against unit-only, and re-run the suite after every source edit.** Two runs
  were discarded this session: one because `xcodegen generate` had run before a new test file
  existed, one because a lint fix landed mid-compile. Both would have reported numbers about a tree
  that no longer existed. And a full run including the UI suite reports a higher coverage figure
  than the unit-only baseline it would be compared against — a number without its measurement basis
  is not a number.

- **An incremental build cannot verify "0 warnings" — only a clean one can.** Repeated runs against
  a warm `-derivedDataPath` reported zero warnings for weeks while
  `ScreenRenderTests.swift` carried an unused `let model`; the file was already compiled, so the
  warning was never re-emitted. It surfaced the first time a fresh clone built from scratch. Verify
  the warning gate against a clean DerivedData, or it is measuring the cache rather than the code.

- **`git status` under-reports in this checkout, and `xcodebuild` will compile the version `git`
  could not see.** A test run reported two failures — a stage table missing `CitationBindingKit`
  and a no-op assertion that got `.ran` — against source that plainly already had both right.
  `PipelineTraceTests.swift` was modified on disk but absent from `git status --short`, because
  iCloud had evicted it; the compiler read the old copy. Running
  `find Sources Tests -name '*.swift' -exec cat {} + > /dev/null` materialised everything, the file
  appeared as modified, and the same suite passed 618/118 with no source change at all. **When a
  failure names code you can see is already correct, materialise before debugging** — the diff you
  are reading and the one that compiled are not necessarily the same diff.

- **A stage can be wired perfectly and still have nothing to do, because an earlier stage never
  gave it anything to work with.** `citationBinding` checks that a claim is supported by the
  document the answer *cited* — but retrieval was injecting passages joined by `---` with no
  identifiers, and nothing in the prompt asked for a citation. `GroundingKit` parsed zero citations
  from every answer, so the stage would have recorded an honest no-op forever and looked wired.
  The fix was upstream: label each passage `[id]` and ask for inline citations. Before concluding a
  package "cannot do useful work in this app", check whether the app is *capable* of producing its
  input — an unverifiable attribution is indistinguishable from a correct one.

- **Two `xcodebuild` runs sharing one `-derivedDataPath` will fight.** A superseded background test
  run was still going when the next one started against `/tmp/aichatapp-coverage-dd`. Stop the old
  task before starting the new one, or give the second run its own path.

- **An iCloud-synced checkout grows `<name> 2.swift` duplicates, and XcodeGen will happily compile
  them.** Five untracked sync-conflict copies (`PipelineStage 2.swift`, `PostModelPipeline 2.swift`,
  two test files, `project 2.yml`) were globbed into the target and failed the build with
  `invalid redeclaration of 'PipelineStage'`. They were stale — all five predated a case committed
  the day before — but nothing in the error says so. Check `git status` for `?? "... 2.swift"`
  before believing a redeclaration error is about your own change.

- **A tuple return cannot grow a third outcome.** `retrievePassages` returned
  `([RetrievedSource], String)` — passages or none. Adding a stage that can conclude *the passages
  contradict each other* had no room in that shape, and the tempting fix is to return no passages
  and let the turn proceed unexplained. It returns a `RetrievalResult` enum instead, so the refusal
  reaches `prepare` rather than being flattened into silence.

- **A verification stage should fail open, and a refusing stage should fail closed. They are not
  the same stage.** `sourceConflict` refuses when the sources genuinely disagree, but records
  `.failed` and admits the passages when the audit itself breaks on malformed input. An audit that
  takes the turn down when *it* is broken is a new failure mode, not a safety feature.

- **The coverage number needs the real `Secrets.xcconfig`, so a fresh clone reads lower and it is
  not a regression.** A clean clone carries only `Secrets.example.xcconfig`, and `coverage.sh`
  against it reports **91.17%** over the same 9311 executable lines — 155 fewer covered than the
  92.84% recorded below. All 601 tests still pass either way. The gap is the provider paths: with
  a placeholder key those tests take their error branches, so the success branches never execute.
  Verifying a fresh clone is still worth doing, but compare its coverage against another
  fresh-clone run, never against the figure measured here.

- **A stage that cannot refuse should say so out loud, not leave the gap unexplained.**
  `claimSegmentation` decides where a claim ends. That is not a policy question — it has no opinion
  about whether the answer is any good — so it records `.ran` or `.noOp` and never `.refused`. The
  refusals this turn can raise belong to grounding and consistency; this stage only changes what
  they are looking at. Written down because "no refusal path" and "refusal path forgotten" look
  identical in a diff.

- **An empty claim list makes a verifier report a clean sweep over nothing.** When
  `ClaimSegmenterKit` finds nothing checkable, the obvious bridge returns `[]` — and
  `GroundingVerifier` then produces a report with no verdicts, no violations, and a decision that
  reads as accepted. An answer nobody checked, published as if it were verified. The bridge falls
  back to `SentenceClaimSegmenter` instead. Standing aside to a coarser check loses granularity;
  standing aside to nothing loses the check.

- **Finer claims are matched worse, not better, by a lexical scorer.** Splitting
  `The client is capped at two retries, and streaming is enabled by default` isolates the false
  half — and then grounding scores `Streaming is enabled by default` against the *cache* document,
  because `is enabled by default` overlaps it more than the streaming source the clause actually
  cited. The smaller a claim gets, the more of its wording it shares with a near neighbour.
  Isolating the clause was necessary and was not sufficient; the fix belongs to the scorer, not the
  segmenter.

- **The stage-table test asserts a count as well as a set.** Adding `ClaimSegmenterKit` to the
  `expected` set left `#expect(expected.count == 29)` untouched and the suite went red on a literal
  rather than on the mapping. That is the reminder working — but read the whole test, not just the
  list.

- **A stage that can refuse must be proven to refuse *through the trace*, not just to return a
  refusal.** `ProviderEffectExecutor` once dropped `resolution.refusal` on the floor, so a turn
  stopped in silence. `claimConsistency` is asserted both ways: the review carries the refusal
  *and* `trace.refusal` finds it, because the second is what actually reaches the banner.

- **Before blaming your own change for a red suite, stash it and re-run.** The 46 UI-test
  failures found this session looked like a regression from wiring in a new pipeline stage.
  Stashing every source change, regenerating the project and running the same `SettingsUITests`
  class reproduced 25 failures identically — the change was not the cause, and an hour of
  bisecting the wrong thing was avoided by one ten-minute control run.

- **Delete the defensive branch you cannot reach rather than testing around it.** A
  `guard !pairs.isEmpty` in the consistency stage looked prudent and was dead: grounding always
  returns at least one verdict for a non-blank answer. Two attempts to reach it (a citation-only
  fragment, an unsegmentable answer) both produced a claim anyway. The checker already refuses
  empty input by name, so the guard went — unreachable code that looks like a safety net is worse
  than none, because it reports as covered risk.

Things that cost real debugging and are not obvious from any documentation.

### OpenRouter

- **Usage arrives in a chunk *after* `finish_reason`.** The stream sends `finish_reason: "stop"`,
  then *another* chunk — same finish reason — carrying `usage`. Breaking out of the loop on the
  first finish reason loses token counts and cost entirely, and the symptom is a chat that works
  perfectly while every cost readout silently shows `$0`.
- The keep-alive is literally `: OPENROUTER PROCESSING`. Any line starting with `:` is an SSE
  comment and must be skipped, or `JSONDecoder` errors on every keep-alive.
- **Five models carry the `-1` pricing sentinel**, not one: `openrouter/auto`, `auto-beta`,
  `fusion`, `pareto-code`, `bodybuilder`. Treating `-1` as a number produces negative costs, and a
  negative added to a running total silently reduces it. The model picker excludes them.
- Pricing is **per-token decimal strings** (`"0.0000025"`); `TokenMeterKit` wants **per-million
  `Decimal`**. Convert with `Decimal(string:)` — via `Double` injects float error into money.
- **`limit: null` means unlimited, not zero.** Never compute `limit - usage` against it.
- Tool calling requires **both** `tools` *and* `tool_choice` in `supported_parameters`. Checking
  only `tools` over-reports capability.
- A function schema must pass `required` through **as authored**. Deriving it from all property
  names makes every optional parameter mandatory — which broke `current_time`'s optional
  `timeZone`, and every argument-less call with it.

### Swift

- **`"\r\n"` is a single extended grapheme cluster.** `split(separator: "\n")` does not match it, so
  a CRLF SSE stream comes back as one un-split blob. Normalise before splitting.
- `[String: Any]` from `Bundle.infoDictionary` breaks a `Sendable` conformance under Swift 6 strict
  concurrency. Flatten to `[String: String]` at the boundary.
- Two initializers with byte-identical bodies get merged by the optimiser and reported as one,
  which reads as a coverage hole no test can close. Have one delegate to the other.
- An xcconfig value treats `//` as a comment, so a bare `https://…` truncates. Assemble URLs from a
  `$(SLASH)` token.
- A XCUITest launches the app as its **own process with no test code linked**, so `URLProtocol`
  stubbing cannot reach it. Anything a UI test needs to control has to be switched inside the app
  on a launch argument — which is why `-UITestMode` swaps the Keychain, biometrics, settings store
  and model catalog.

### Package collisions (these break the build)

| Symbol | Defined in | Note |
|---|---|---|
| `ToolRegistry` | ToolRegistryKit **and** ProviderGatewayKit | Both actors, both with `register`/`unregister`. Composition qualifies as `ToolRegistryKit.ToolRegistry` |
| `ToolCallRequest` | ToolRegistryKit (`argumentsJSON: Data`) **and** ProviderGatewayKit (`arguments: [String: LLMToolArgumentValue]`) | Different shapes; PGK's `id` has a default, TRK's does not |
| `RouterError` | SemanticRouterKit **and** ProviderGatewayKit | Semantically unrelated |
| `Route` | SemanticRouterKit | Collides with the conventional SwiftUI navigation enum |
| `JSONValue` | StructuredOutputKit | This app's wire type is named `OpenRouterJSON` to avoid it |
| `CompactionEvent` | ContextCompactionKit **and** WorkloadProfilerKit | |
| `TokenUsage` | TokenMeterKit, CostEstimatorKit, StreamAggregatorKit | Three different shapes |

### Package behaviour that surprised

- **`IdempotencyGuard` freezes the key on an unclassified error.** Sound reasoning — an unknown
  failure might have applied — but it means a rate-limited turn freezes that exact message forever.
  `ProviderEffectExecutor` classifies: 429/401/402 throw `EffectFailure(mode: .notApplied)`
  (provably nothing was charged); a mid-stream drop stays `.indeterminate`.
- The guard also **replaces the executor's error with its own**, so `ProviderError` never survives
  to the caller. The executor remembers it separately, or every failure renders as one banner.
- **`ToolRegistry` renders a thrown handler error with a bare `"\(error)"`** and never consults
  `LocalizedError`. An `NSError` there dumps a domain and a URL into a chat bubble, so every tool
  error type conforms to `CustomStringConvertible`.
- **`SchemaRegistry.register` throws on a second call for the same contract.** It must be
  registered once per process — never in a SwiftUI `.task`, which re-runs on identity change and
  would take the whole metadata feature down on a redraw.
- **`LLMSession.currentTranscript()` drops the user's message on a failed turn.** Correct for a
  transcript it will resend, wrong for a chat log. The view model owns its own `[ChatBubble]`.
- `LLMRequest.init` has `precondition`s on temperature and `maxOutputTokens` — these **trap in
  release**. Settings clamps before constructing.
- **Two untagged repos broke `xcodegen`/SPM resolution**, both with the same message: "no versions
  of X match the requirement 1.0.0..<2.0.0". `spotlight-rag-kit` and `llm-eval-harness-kit` were
  both pushed without a tag, and `from:` cannot resolve against a repo that has none.
- **`swift test`'s tail lies about an XCTest-only package.** It prints `Test run with 0 tests in 0
  suites` — that line belongs to the swift-testing runner, and the XCTest tally sits above it.
  Reading the tail alone reports a healthy package as broken.
- **A test asserting concurrent call *ordering* passes until it doesn't.** `MetadataPipelineTests`
  documented in a comment that interleaving is a scheduling outcome and switched to counting, then
  kept one `calls.last ==` assertion anyway. Adding an `await` earlier in `generate` flipped it.
- **`AuthorityBroker` throws rather than returns for host mistakes**, and three of those throws are
  reachable from ordinary use: re-presenting a spent `Approval`, presenting an expired one, and
  presenting one for a capability that needs none. All three surface as `.failed` — "the system
  broke" — for what is really a user asking twice. The app spends its own copy as it presents it.
- `QuotaGovernorKit` takes `Int` ticks and refuses to go backwards, so the app owns a monotonic
  counter rather than reading a clock. Its ledger is also in memory, so the month's spend total is
  persisted separately by `AppSettingsStore`.
- `MeterReport.formatted()` is fixed-width ASCII — do not render it in SwiftUI.
- `SemanticRouter.route(_:)` returning `nil` is the **normal** path. Treating it as failure builds
  a chat app that refuses off-topic questions.
- The bundled embedders are bag-of-words: synonyms score 0. Seed routes with the literal words
  users type.

### Two deliberate departures

Both were judged and rejected rather than overlooked:

- **The `tool` role is not used on the wire.** `LLMMessage` cannot carry `tool_calls`, so the
  canonical OpenAI pairing (assistant message with `tool_calls`, then a `tool` message with
  `tool_call_id`) cannot be expressed through `LLMRequest`. A bare `tool` message risks a 400 from
  strict upstreams, so the observation returns as a `user` message in AgentLoopKit's own
  `Tool "x" returned: {…}` format. `ToolCallResult.id` is carried into the `AgentStep`; it just
  does not reach the wire as `tool_call_id`.
- **`AgentLoop.run` is not driven.** It makes the first model call itself over an
  `LLMSession`/`ProviderRouter`, bypassing this app's SSE transport, streaming, idempotency guard
  and usage recorder — and with `supportsToolCalling: true` the router runs its own stringly-typed
  tool round trips underneath, fighting the native one. Four of its public types do real work
  instead: `DefaultAgentPromptStrategy` formats every observation, and
  `AgentTranscript`/`AgentStep`/`AgentHaltReason` model the hop and produce the `.agentLoop`
  outcome.

---

## Coverage

**93.96%** — 10554/11233 lines, unit tests only. Every file in `Sources/Core/Pipeline/` is at 100%,
as is `Sources/Core/Tools/SelectionTrustGate.swift` (94/94) added this change. 28 files
sit below it, and they divide into two groups that want different answers:

**The view layer, exercised by XCUITest rather than by the unit target.** A unit-only run reports
these as gaps whatever the UI suite is doing. The suite is now green, which does not move these
numbers — the two targets are measured separately and only the unit-only figure is comparable
across runs.

| File | Coverage |
|---|---|
| `AppNavigation.swift` | 24.15% |
| `ChatViewModel+Derived.swift` | 55.56% |
| `ChatView.swift` | 78.51% |
| `AIChatApp.swift` | 79.05% |
| `SettingsView.swift` | 86.08% |
| `ProfileView.swift` | 88.44% |
| `ChatViewModel.swift` | 88.48% |
| `ChatListView.swift` | 93.15% |
| `MessageActions.swift` | 93.45% |
| `ModelPickerView.swift` | 95.35% |
| `SettingsSections.swift` | 96.33% |

**Branches a test cannot reach.** Real device hardware, a forced OS-level failure, or a state the
surrounding types make unreachable. Closing these would mean adding seams whose only caller is a
test — worth doing for `KeychainStore` (already done once), not for `LAContext.biometryType`.

| File | Coverage | What is uncovered |
|---|---|---|
| `Composition.swift` | 87.61% | provider-assembly branches taken only with a live key |
| `UserProfile.swift` | 91.74% | |
| `Authentication.swift` | 94.32% | `LAContext` biometry-type branches needing real hardware |
| `AssistantAvatar.swift` | 96.77% | |
| `Conversation.swift` | 97.04% | |
| `AppSettingsStore.swift` | 97.14% | |
| `ReasoningEffort.swift` | 97.62% | |
| `ProviderEffectExecutor.swift` | 98.58% | retry-sleep branch, `Task.isCancelled` guard |
| `OpenRouterEmbeddingProvider.swift` | 98.61% | |
| `TurnExecutor+Support.swift` | 98.65% | |
| `PreModelPipeline+SourceConflict.swift` | 98.82% | |
| `TurnExecutor.swift` | 98.86% | |
| `OpenRouterProvider.swift` | 98.91% | |
| `ModelPicker.swift` | 98.97% | |
| `KeychainStore.swift` | 98.99% | one `SecItem` OSStatus path |
| `PreModelPipeline.swift` | 99.07% | |
| `ToolAuthorityGate.swift` | 99.48% | `.failed` verdict — needs a thrown `AuthorityError` this call shape cannot produce |

`COVERAGE_THRESHOLD=100 ./Scripts/coverage.sh` exits non-zero, by design: the number is honest
rather than gamed.

---

## Remaining work

- **Coverage is measured on unit tests only, and is not comparable to the 99.33% recorded
  earlier.** That figure included the UI tests; this one does not, which is most of why
  `AppNavigation` sits at 24%. The genuine regression underneath it was real though:
  `ProfileView` had reached **0%** because it shipped with no render test, and nothing
  re-measured after the profile and history work. Render tests brought the total from 86.91% to
  92.62%. Restoring a full-suite number needs the UI tests fixed first.
- **Six UI tests need rework for the new navigation.** Written against a two-level hierarchy
  (chat → destination) when there are now three (list → chat → destination), so the back button
  they tap belongs to a different screen and the Diagnostics rows sit one push deeper.
- **`AccentColor` is still unused.** Nothing sets
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, so the system default blue renders. The
  assistant avatar hardcodes the icon's gradient rather than reading an accent that would not
  match.
- **Effort is one value for the provider.** `ReasoningEffortBox` is per-provider, not
  per-request — `LLMRequest` cannot carry it without forking ProviderGatewayKit. Two conversations
  sending at the same instant would share whichever was set last; this app sends one turn at a time.
- **No audited subset, so the derived correctness labels cannot be priced.** The `proxyLabel`
  stage derives a label for every gate on every turn that had an outcome, and then refuses to do
  anything with them: pricing needs somebody to read turns and record which gate was actually
  right, and there is no screen, store or gesture for that. `MetadataPipeline.auditedTurns` is an
  empty `AuditSample` named so the gap is visible, and the stage takes one as a parameter so the
  day a review surface exists it starts pricing without being rewritten. Until then
  `effectiveVote` stays on vote agreement, which is the weaker of its two bases.
- **A real corpus.** `AppKnowledge` is four passages about the app itself.
- **CoreSpotlight.** The app uses `InMemorySearchIndex`; CoreSpotlight does not index reliably in
  a simulator.
- **Profile photos.** Avatars are monograms.

## Layout

```
AIChatApp/
├── project.yml                 XcodeGen — 45 packages + swift-snapshot-testing
├── Secrets.xcconfig            gitignored
├── Secrets.example.xcconfig    committed
├── Config/                     Base / Debug / Release xcconfig
├── Scripts/coverage.sh         per-file coverage, gates on a threshold
├── Sources/
│   ├── App/                    entry point, RootView, Composition
│   ├── Core/
│   │   ├── Secrets/            Keychain + resolution order
│   │   ├── OpenRouter/         provider, SSE, wire types, model catalog
│   │   ├── Pipeline/           stages, trace, pre/post-model, executor
│   │   ├── Tools/              calculator + clock, authority gate, round trip
│   │   └── Metadata/           title + follow-ups: schema, contract, repair, batch
│   └── Features/               design system, login, chat, models, settings, diagnostics
└── Tests/
    ├── AIChatAppTests/         487 unit + integration + snapshot
    └── AIChatAppUITests/       24 XCUITest
```

## License

MIT
