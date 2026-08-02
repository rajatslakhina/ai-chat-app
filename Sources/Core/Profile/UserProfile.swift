import Foundation
import SwiftUI

/// One person using this install.
///
/// There is no backend, so a "user" is local and switchable rather than authenticated. That is the
/// honest shape: the login screen already says there is no server, and inventing accounts on top
/// of a hardcoded demo credential would imply an identity the app cannot actually verify. What a
/// profile really owns is scope — its own conversations and its own settings.
struct UserProfile: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var displayName: String
    var email: String
    /// Picks the avatar's colour. Stored rather than derived from the name so a profile keeps its
    /// colour when renamed.
    var avatarSeed: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        email: String = "",
        avatarSeed: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.avatarSeed = avatarSeed
        self.createdAt = createdAt
    }

    /// Up to two initials. Empty when there is nothing to take them from, so the avatar can fall
    /// back to a glyph rather than render a blank circle, which reads as a failed image load.
    var monogram: String {
        let letters = displayName
            .split(separator: " ")
            .compactMap { $0.first.map(String.init) }
        return letters.prefix(2).joined().uppercased()
    }

    static let avatarPalette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal]

    var avatarColor: Color {
        // Modulo rather than a bounds check: a seed written by an older build, or edited by hand,
        // must not index out of a palette that may later shrink.
        UserProfile.avatarPalette[abs(avatarSeed) % UserProfile.avatarPalette.count]
    }

    /// The profile a fresh install starts with, named after the demo account it signs in as.
    static func bootstrap() -> UserProfile {
        UserProfile(displayName: "Demo", email: DemoAccount.email, avatarSeed: 0)
    }
}

/// Where profiles survive a relaunch.
protocol ProfilePersisting: Sendable {
    func loadProfiles() -> Data?
    func saveProfiles(_ data: Data)
}

struct UserDefaultsProfiles: ProfilePersisting {
    static let key = "profiles.v1"

    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProfiles() -> Data? { defaults.data(forKey: Self.key) }

    func saveProfiles(_ data: Data) { defaults.set(data, forKey: Self.key) }
}

/// Profiles that vanish with the process, for UI tests and unit tests.
final class InMemoryProfiles: ProfilePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(seed: Data? = nil) { self.stored = seed }

    func loadProfiles() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func saveProfiles(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored = data
    }
}

/// The on-disk shape.
private struct PersistedProfiles: Codable {
    var profiles: [UserProfile]
    var activeID: UUID
}

/// Who is using the app, and which of them is active.
///
/// Always non-empty. A list that can reach zero forces every reader to handle "no active profile",
/// which is a state the app has no screen for — deleting the last one re-bootstraps instead.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [UserProfile]
    private(set) var activeID: UUID

    private let persistence: any ProfilePersisting

    init(persistence: any ProfilePersisting = UserDefaultsProfiles()) {
        self.persistence = persistence
        guard let data = persistence.loadProfiles(),
              let decoded = try? JSONDecoder().decode(PersistedProfiles.self, from: data),
              !decoded.profiles.isEmpty else {
            let bootstrap = UserProfile.bootstrap()
            self.profiles = [bootstrap]
            self.activeID = bootstrap.id
            return
        }
        self.profiles = decoded.profiles
        // An active id naming a profile that no longer exists would leave every scoped read
        // pointing at nothing, so it is repaired on load rather than trusted.
        self.activeID = decoded.profiles.contains { $0.id == decoded.activeID }
            ? decoded.activeID
            : decoded.profiles[0].id
    }

    var active: UserProfile {
        // Total in practice: the list is never empty and `activeID` is repaired on load and on
        // delete. The fallback is here because trapping over a lookup would take the app down.
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }), id != activeID else { return }
        activeID = id
        persist()
    }

    @discardableResult
    func addProfile(displayName: String, email: String = "") -> UserProfile {
        let profile = UserProfile(
            displayName: Self.cleaned(displayName),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarSeed: profiles.count
        )
        profiles.append(profile)
        activeID = profile.id
        persist()
        return profile
    }

    func update(_ profile: UserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var edited = profile
        edited.displayName = Self.cleaned(profile.displayName)
        edited.email = profile.email.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index] = edited
        persist()
    }

    /// Removes a profile. Deleting the last one re-bootstraps rather than leaving none.
    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [UserProfile.bootstrap()] }
        if !profiles.contains(where: { $0.id == activeID }) { activeID = profiles[0].id }
        persist()
    }

    /// A blank name renders as an empty avatar and an empty row, so it is replaced rather than
    /// rejected — an editing screen that refuses to close is worse than a sensible default.
    private static func cleaned(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private func persist() {
        let snapshot = PersistedProfiles(profiles: profiles, activeID: activeID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        persistence.saveProfiles(data)
    }
}
