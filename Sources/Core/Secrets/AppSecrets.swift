import Foundation

/// Where the OpenRouter key came from, kept so Settings can tell the user the truth.
///
/// "Configured" is not one state. A key baked into the build at archive time and a key the user
/// typed on this device behave identically at the network layer but differently at every other
/// level: only one of them can be cleared, and only one of them explains why a TestFlight build
/// works when a fresh clone does not.
enum SecretOrigin: String, Sendable, Equatable {
    /// Typed by the user in Settings, or migrated there from the build and since edited.
    case keychain
    /// Supplied by `Secrets.xcconfig` through Info.plist, then promoted into the Keychain.
    case buildConfiguration
    /// Injected by a UI test launch argument. Never leaves the simulator.
    case testHarness
    /// No key anywhere. A legitimate state: the app runs and routes the user to Settings.
    case absent
}

/// Reads configuration that must not be hard-coded, in a fixed order of precedence.
///
/// The order matters and is deliberate:
///
/// 1. **Test harness** — a UI test must be able to pin the app into a known state without the
///    device's real Keychain leaking into the run, or the run leaking into the device.
/// 2. **Keychain** — what the user last set on this device wins over what was baked in, so
///    replacing a revoked key in Settings actually takes effect.
/// 3. **Build configuration** — `Secrets.xcconfig` via Info.plist. On first launch this is
///    promoted into the Keychain so that step 2 owns it from then on.
/// 4. **Absent** — no key. The app must still launch. A configuration reader that traps on a
///    missing key turns "I have not set this up yet" into a crash report.
///
/// `Secrets.xcconfig` is gitignored, so a fresh clone lands in state 4 rather than failing to
/// build, and the app says so on screen instead of failing at the first request.
struct AppSecrets: Sendable {
    static let apiKeyAccount = "openrouter.api-key"

    /// Launch argument a UI test passes to supply a fake key: `-OpenRouterAPIKey <value>`.
    static let testKeyLaunchArgument = "-OpenRouterAPIKey"

    private let store: any SecretStoring
    /// The Info.plist values this type reads, flattened to strings at init.
    ///
    /// `Bundle.main.infoDictionary` is `[String: Any]`, which is not `Sendable` — holding it
    /// would make this struct's `Sendable` conformance a lie under Swift 6 strict concurrency.
    /// Only three string keys are ever read, so they are extracted once and the untyped
    /// dictionary is dropped at the boundary.
    private let info: [String: String]
    private let launchArguments: [String]

    private(set) var origin: SecretOrigin = .absent

    private static let readKeys = ["OpenRouterAPIKey", "OpenRouterSiteURL", "OpenRouterAppName"]

    init(
        store: any SecretStoring = KeychainStore(),
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.store = store
        let source = infoDictionary ?? [:]
        var flattened: [String: String] = [:]
        for key in Self.readKeys {
            if let value = source[key] as? String { flattened[key] = value }
        }
        self.info = flattened
        self.launchArguments = launchArguments
    }

    /// Convenience for tests, which have no bundle worth reading.
    init(
        store: any SecretStoring,
        info: [String: String],
        launchArguments: [String] = []
    ) {
        self.store = store
        self.info = info
        self.launchArguments = launchArguments
    }

    /// The key, resolved once at launch. Promotes a build-supplied key into the Keychain as a
    /// side effect, which is the only write this type performs on its own initiative.
    mutating func resolveAPIKey() -> String? {
        if let injected = launchArgumentValue(for: Self.testKeyLaunchArgument) {
            origin = .testHarness
            return injected.isEmpty ? nil : injected
        }
        if let stored = try? store.string(for: Self.apiKeyAccount), !stored.isEmpty {
            origin = .keychain
            return stored
        }
        if let baked = infoValue(for: "OpenRouterAPIKey") {
            // Promote once, so Settings can later replace it and have the replacement win.
            try? store.set(baked, for: Self.apiKeyAccount)
            origin = .buildConfiguration
            return baked
        }
        origin = .absent
        return nil
    }

    /// Replaces the key from Settings. An empty string clears it rather than storing blank.
    func updateAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try store.remove(Self.apiKeyAccount)
        } else {
            try store.set(trimmed, for: Self.apiKeyAccount)
        }
    }

    /// `HTTP-Referer`, which OpenRouter attributes usage to. Optional to the API, so a missing
    /// value is omitted rather than sent empty.
    var siteURL: String? { infoValue(for: "OpenRouterSiteURL") }

    /// `X-Title`, the name shown on OpenRouter's activity page.
    var appName: String? { infoValue(for: "OpenRouterAppName") }

    /// Reads an Info.plist string, treating empty and un-substituted values as absent.
    ///
    /// A build with no `Secrets.xcconfig` leaves `$(OPENROUTER_API_KEY)` unexpanded or empty.
    /// Both must read as "no key" — sending the literal string `$(OPENROUTER_API_KEY)` as a
    /// bearer token would produce a 401 that looks like a bad key rather than a missing one.
    private func infoValue(for key: String) -> String? {
        guard let raw = info[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// The key as Settings shows it.
    ///
    /// Prefix and last four, which is how OpenRouter labels keys on its own dashboard
    /// (`sk-or-v1-c4d...906`). Enough to tell two keys apart or confirm the right one is loaded;
    /// not enough to spend with, and not enough to matter in a screenshot. A short value is
    /// replaced entirely rather than partly shown — the "prefix plus suffix" rule leaks most of an
    /// eight-character string.
    static func mask(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: max(4, key.count)) }
        return String(key.prefix(8)) + "…" + String(key.suffix(4))
    }

    private func launchArgumentValue(for flag: String) -> String? {
        guard let index = launchArguments.firstIndex(of: flag) else { return nil }
        let next = launchArguments.index(after: index)
        guard next < launchArguments.endIndex else { return "" }
        return launchArguments[next]
    }
}

extension SecretOrigin {
    /// What Settings shows about where the current key came from.
    var settingsDescription: String {
        switch self {
        case .keychain:
            return "Stored on this device"
        case .buildConfiguration:
            return "Loaded from Secrets.xcconfig at build time"
        case .testHarness:
            return "Injected by a test run"
        case .absent:
            return "Not configured"
        }
    }

    /// What "Delete key" actually does, which is not the same thing in every origin.
    ///
    /// Here rather than inside the Settings view for the same reason `settingsDescription` is: the
    /// rule belongs to the origin, and a `switch` buried in a `body` is a rule that can only be
    /// checked by looking at it. The build-configuration case is the one that matters — deleting a
    /// key `Secrets.xcconfig` supplies clears this device's copy and nothing else, and the next
    /// launch promotes it straight back.
    var keyManagementNote: String {
        switch self {
        case .buildConfiguration:
            return "This key came from Secrets.xcconfig. Deleting it clears the copy stored on "
                + "this device, but the build still supplies one, so it will come back on the "
                + "next launch. Replace it to override the build."
        case .testHarness:
            return "Injected by a launch argument for this run only. Nothing was written to the "
                + "Keychain."
        case .keychain, .absent:
            return "Stored in the Keychain, this device only, never synced to iCloud and never "
                + "included in a backup that could restore it elsewhere. Changing the key "
                + "rebuilds the pipeline and starts a new conversation."
        }
    }
}
