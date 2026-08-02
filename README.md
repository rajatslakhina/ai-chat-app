# AI Chat

A SwiftUI iOS chat client for [OpenRouter](https://openrouter.ai), built on the 26-package Swift
LLM ecosystem from [`llm-ecosystem-demo`](https://github.com/rajatslakhina/llm-ecosystem-demo).

Every message runs through a real pipeline — prompt templating, PII guardrails, semantic routing,
caching, retrieval, compaction, cost forecasting, budget reservation, retries, streaming, tool
round-tripping, metering, settlement, answer screening and claim grounding — and **every refusal is
surfaced to the user with the stage that caused it and the action that resolves it**.

---

## Status

Measured on Swift 6.2.4 / Xcode 26.3 / macOS 26.5.2, iPhone 17 Pro simulator.

| Gate | Result |
|---|---|
| `xcodebuild build` | 0 errors, 0 warnings |
| Unit + integration tests | **501 passing**, 100 suites |
| UI tests (XCUITest) | **24 passing** |
| `swiftlint --strict` | **0 violations**, 48 files |
| Line coverage | **98.93%** — 6826/6900 |
| Verified against the live API | Yes — real answers, real token counts, real cost |

**All 26 packages do real work in the send path.** All 27 pipeline stages have a live recording call
site. 74 lines remain uncovered; see [Coverage](#coverage).

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
      │     template → guardrail(in) → route → cache → memory → retrieval → compaction
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
            batch(title ∥ follow-ups) → decode → repair → migrate
```

The split is at the point the turn stops being free. Everything before `TurnExecutor` is local
computation; everything inside it either costs money or exists to control what it costs.

Screens: login → chat → model picker, settings, diagnostics.

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

**99.55%** — 6412/6441 lines. 36 files are at 100%. The remaining 29 lines sit in 12 files:

| File | Coverage | What is uncovered |
|---|---|---|
| `Authentication.swift` | 98.11% | `LAContext` biometry-type branches needing real hardware |
| `ProviderEffectExecutor.swift` | 98.58% | retry-sleep branch, `Task.isCancelled` guard |
| `TurnExecutor+Support.swift` | 98.65% | |
| `Composition.swift` | 98.70% | |
| `TurnExecutor.swift` | 98.81% | |
| `KeychainStore.swift` | 98.99% | one `SecItem` OSStatus path |
| `ToolAuthorityGate.swift` | 99.12% | `.failed` verdict — needs a thrown `AuthorityError` this call shape cannot produce |
| `OpenRouterProvider.swift` | 99.26% | |
| `ModelPickerView.swift` | 99.34% | |
| `ChatViewModel.swift` | 99.36% | |
| `ChatView.swift` | 99.62% | |
| `SettingsSections.swift` | 99.66% | |

These are branches reachable only with real device hardware, a forced OS-level failure, or a state
the surrounding types make unreachable. Closing them would mean adding seams whose only caller is a
test — worth doing for `KeychainStore` (already done once), not worth it for `LAContext.biometryType`.

`COVERAGE_THRESHOLD=100 ./Scripts/coverage.sh` exits non-zero, by design: the number is honest
rather than gamed.

---

## Remaining work

- **A real embedder.** `HashingEmbeddingProvider` and `HashingRouteEmbedder` are bag-of-words;
  routing and retrieval both improve materially with a hosted embeddings endpoint behind the same
  protocols. OpenRouter does expose one — `POST /api/v1/embeddings`, OpenAI-shaped, same key, no
  streaming — so this needs no second provider. The trap to avoid: do **not** fall back between the
  hashing and hosted embedders per call. Their dimensions differ, so one index would mix vector
  widths and cosine similarity would return confident nonsense rather than a degraded result.
  Choose one embedder at composition time from whether a key is present, and throw on failure.
- **Coverage back to 99.55%.** The approval feature landed at 98.93%: `ChatViewModel`'s approval
  extension (29 lines) and `ChatView`'s sheet wiring (18) need a test that settles the `Task`
  behind `beginApproval`, which the existing `settle(_:)` helper does not cover.

---

## Layout

```
AIChatApp/
├── project.yml                 XcodeGen — 26 packages + swift-snapshot-testing
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
