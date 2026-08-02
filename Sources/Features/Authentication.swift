import LocalAuthentication
import SwiftUI

/// The demo account this build ships with.
///
/// A seeded credential, not a backend. Stated plainly in the UI too — a login screen that looks
/// real but accepts anything teaches the wrong thing about the app, and one that looks real and
/// silently stores a password teaches something worse.
enum DemoAccount {
    static let email = "demo@aichat.app"
    static let passphrase = "letmein"
}

/// Why a sign-in attempt failed, in the words the field should show.
enum SignInFailure: Equatable {
    case emptyEmail
    case emptyPassphrase
    case wrongCredentials
    case biometricsUnavailable(String)
    case biometricsFailed(String)

    var message: String {
        switch self {
        case .emptyEmail: return "Enter the demo email address."
        case .emptyPassphrase: return "Enter the demo passphrase."
        case .wrongCredentials: return "That isn't the demo account."
        case let .biometricsUnavailable(reason): return reason
        case let .biometricsFailed(reason): return reason
        }
    }
}

/// Abstracts Face ID so the flow is testable.
///
/// `LAContext` cannot be exercised in a unit test or driven from a UI test, so the one seam that
/// matters — "did biometrics succeed?" — is a protocol. Without it, the unlock path would only
/// ever be verified by hand.
protocol BiometricAuthenticating: Sendable {
    var isAvailable: Bool { get }
    var displayName: String { get }
    func authenticate(reason: String) async throws -> Bool
}

struct FaceIDAuthenticator: BiometricAuthenticating {
    var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
    }

    var displayName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    func authenticate(reason: String) async throws -> Bool {
        try await LAContext().evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
    }
}

/// Always-unavailable biometrics, for simulators and UI tests.
struct UnavailableBiometrics: BiometricAuthenticating {
    var isAvailable: Bool { false }
    var displayName: String { "Biometrics" }
    func authenticate(reason: String) async throws -> Bool { false }
}

/// Session state for the demo login.
///
/// `UserDefaults` rather than the Keychain on purpose: this is a mock session with no secret in
/// it. Putting a meaningless boolean in the Keychain would imply a protection it does not have,
/// and the real secret — the OpenRouter key — already lives there via `AppSecrets`.
@MainActor
@Observable
final class AuthStore {
    private(set) var isSignedIn: Bool
    private(set) var failure: SignInFailure?
    private(set) var isWorking = false

    private let biometrics: any BiometricAuthenticating
    private let persist: @MainActor (Bool) -> Void

    var biometricsAvailable: Bool { biometrics.isAvailable }
    var biometricsName: String { biometrics.displayName }

    static let storageKey = "session.signedIn"

    init(
        isSignedIn: Bool = false,
        biometrics: any BiometricAuthenticating = FaceIDAuthenticator(),
        persist: @escaping @MainActor (Bool) -> Void = { value in
            UserDefaults.standard.set(value, forKey: AuthStore.storageKey)
        }
    ) {
        self.isSignedIn = isSignedIn
        self.biometrics = biometrics
        self.persist = persist
    }

    /// Restores a session, unless a UI test asked for a clean launch.
    static func restored(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> AuthStore {
        guard !arguments.contains("-UITestMode") else {
            return AuthStore(
                isSignedIn: arguments.contains("-SignedIn"),
                biometrics: UnavailableBiometrics(),
                persist: { _ in }
            )
        }
        return AuthStore(isSignedIn: defaults.bool(forKey: storageKey))
    }

    func signIn(email: String, passphrase: String) {
        failure = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            failure = .emptyEmail
            return
        }
        guard !passphrase.isEmpty else {
            failure = .emptyPassphrase
            return
        }
        guard trimmedEmail.caseInsensitiveCompare(DemoAccount.email) == .orderedSame,
              passphrase == DemoAccount.passphrase else {
            failure = .wrongCredentials
            return
        }
        setSignedIn(true)
    }

    func unlockWithBiometrics() async {
        failure = nil
        guard biometrics.isAvailable else {
            failure = .biometricsUnavailable(
                "\(biometrics.displayName) isn't set up on this device."
            )
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let recognised = try await biometrics.authenticate(reason: "Unlock AI Chat")
            if recognised {
                setSignedIn(true)
            } else {
                failure = .biometricsFailed("\(biometrics.displayName) didn't recognise you.")
            }
        } catch {
            failure = .biometricsFailed(error.localizedDescription)
        }
    }

    func signOut() {
        setSignedIn(false)
    }

    private func setSignedIn(_ value: Bool) {
        isSignedIn = value
        persist(value)
    }
}

/// The demo sign-in screen.
struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @State private var email = ""
    @State private var passphrase = ""
    @FocusState private var focus: Field?

    private enum Field { case email, passphrase }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.loose) {
                header
                credentials
                actions
                demoHint
            }
            .padding(Theme.Spacing.loose)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Palette.canvas)
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.snug) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("AI Chat")
                .font(Theme.Typeface.title)
            Text("A chat client built on 25 Swift packages, talking to OpenRouter.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Spacing.section)
    }

    private var credentials: some View {
        VStack(spacing: Theme.Spacing.snug) {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.next)
                .onSubmit { focus = .passphrase }
                .accessibilityIdentifier("emailField")

            SecureField("Passphrase", text: $passphrase)
                .textContentType(.password)
                .focused($focus, equals: .passphrase)
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityIdentifier("passphraseField")

            if let failure = auth.failure {
                Text(failure.message)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.failure)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("loginError")
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.snug) {
            Button(action: submit) {
                Text("Sign in")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(auth.isWorking)
            .accessibilityIdentifier("signInButton")

            if auth.biometricsAvailable {
                Button {
                    Task { await auth.unlockWithBiometrics() }
                } label: {
                    Label("Unlock with \(auth.biometricsName)", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(auth.isWorking)
                .accessibilityIdentifier("biometricButton")
            }
        }
    }

    private var demoHint: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Label("Demo account", systemImage: "info.circle")
                .font(Theme.Typeface.heading)
            Text("\(DemoAccount.email) · \(DemoAccount.passphrase)")
                .font(Theme.Typeface.metric)
            Text(
                "There is no backend. This screen checks a seeded credential so the flow is real "
                    + "without pretending an account exists."
            )
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func submit() {
        focus = nil
        auth.signIn(email: email, passphrase: passphrase)
    }
}
