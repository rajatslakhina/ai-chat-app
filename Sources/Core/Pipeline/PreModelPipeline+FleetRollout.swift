import FleetRollout
import Foundation

/// Whether this install's semantic-routing capability is allowed, decided by `FleetRolloutKit`
/// on top of `PipelineSettings.routingEnabled`.
///
/// A settings toggle is not how a fleet-wide kill actually gets found in an incident — it is
/// something a user has to already know exists and go looking for. This gate is the other half:
/// a document this app ships with that can turn routing off for every install on the next build,
/// independent of whatever an individual Settings screen says.
///
/// `FleetRolloutKit`'s own README argues for `ConfigStore(bundledFallback:)` — a document the app
/// ships with, evaluated with no network call — as the correct shape for an app with no remote
/// config backend of its own. This app has none, so the bundled document *is* the operative one,
/// and `Evaluator` alone (no store, no transport) is the right amount of the package to use: a
/// pure function of a document this build carries, exactly like `FleetSimulator` runs the real
/// evaluator over a fleet it never talks to.
enum FleetRolloutGate {
    static let flagKey = "chat.semantic_routing"

    /// Shipped with the app. Killing this in a future build is how routing would actually be
    /// turned off fleet-wide; there is deliberately no rollout rule here today, because standing
    /// up a canary population for a chat client's own router is a decision for whoever owns that
    /// feature, not something this stage should invent evidence for.
    static let document: ConfigDocument = {
        let flag = FlagDefinition(
            key: flagKey,
            salt: "aichatapp-fleet-salt",
            variants: [Variant(key: "on", value: .bool(true)), Variant(key: "off", value: .bool(false))],
            defaultVariantKey: "on",
            rules: [])
        return ConfigDocument(
            documentVersion: 1, issuedAt: Date(timeIntervalSince1970: 1_758_585_600), flags: [flag])
    }()

    /// The compiled-in fallback used for a killed flag, an unresolvable one, or no document at
    /// all. `.bool(false)` on purpose: a kill switch that fell back to "on" would not be one.
    static let evaluator = Evaluator(
        document: document, fallback: FallbackCatalog(values: [flagKey: .bool(false)]))

    /// A stable per-install identifier, persisted the way `FleetRolloutKit`'s own docs recommend:
    /// generated once and kept in `UserDefaults` rather than read from `identifierForVendor`,
    /// which resets when the last app from this vendor is removed and would silently re-bucket
    /// every returning install.
    static let identifierKey = "com.rajatslakhina.aichatapp.fleetRolloutIdentifier"

    static func sessionDevice(defaults: UserDefaults = .standard) -> DeviceContext {
        let identifier: String
        if let saved = defaults.string(forKey: identifierKey) {
            identifier = saved
        } else {
            identifier = UUID().uuidString
            defaults.set(identifier, forKey: identifierKey)
        }
        return DeviceContext(
            stableIdentifier: identifier, buildTrain: .ios27_2, deviceClass: .phoneStandard,
            posture: .fixed, appBuild: 1)
    }

    static func evaluate(defaults: UserDefaults = .standard) -> Assignment {
        evaluator.evaluate(flagKey, for: sessionDevice(defaults: defaults))
    }
}

extension PreModelPipeline {
    /// Pure: maps a resolved `Assignment` to what the stage records and whether routing may
    /// proceed. Split out of `fleetRolloutGate` so every `EvaluationReason` — including ones the
    /// bundled document cannot currently produce, like `.killed` — is directly testable, the same
    /// way `MetadataPipeline.conditioningRead` is tested apart from the pipeline that calls it.
    static func fleetRolloutDecision(_ assignment: Assignment) -> (allowed: Bool, outcome: StageOutcome) {
        // Not `?? true`: a nil-coalescing operator's right-hand side is an autoclosure, and a
        // trivial literal one is a region the optimizer can eliminate entirely, which then never
        // registers as covered no matter what a test drives through it. An explicit if/else has
        // no such region.
        let allowed: Bool
        if let boolValue = assignment.value.boolValue {
            allowed = boolValue
        } else {
            allowed = true
        }
        switch assignment.reason {
        case .killed:
            return (allowed, .skipped(reason: "semantic routing killed fleet-wide"))
        case .ruleMatch, .defaultVariant:
            return (
                allowed,
                allowed
                    ? .noOp(reason: "session is in the routing rollout")
                    : .skipped(reason: "session is outside the routing rollout")
            )
        case .unknownFlag, .noDocument, .refusedMalformedRule:
            return (allowed, .failed(message: "flag resolution fell back: \(assignment.reason.rawValue)"))
        }
    }

    /// Runs before `chooseModel`, because the fleet gate decides whether routing is even a
    /// candidate for this turn — the same ordering reason templating runs before the guardrail
    /// screens the rendered text: a later stage should see the decision already made, not remake
    /// part of it.
    ///
    /// `static` rather than an instance method: the decision depends only on the bundled document
    /// and this install's identifier, neither of which lives on `PreModelPipeline`.
    static func fleetRolloutGate(trace: inout PipelineTrace) -> Bool {
        let (allowed, outcome) = fleetRolloutDecision(FleetRolloutGate.evaluate())
        trace.record(.fleetRollout, outcome)
        return allowed
    }
}
