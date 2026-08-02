import SwiftUI

/// Who is using the app, and how to become someone else.
struct ProfileView: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(AuthStore.self) private var auth

    @State private var editing: UserProfile?
    @State private var addingName = ""
    @State private var isAdding = false

    var body: some View {
        List {
            activeSection
            switchSection
            addSection
            signOutSection
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { profile in
            EditProfileView(profile: profile) { profiles.update($0) }
        }
    }

    private var activeSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.snug) {
                ProfileAvatar(profile: profiles.active, diameter: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profiles.active.displayName)
                        .font(Theme.Typeface.heading)
                        .accessibilityIdentifier("profileName")
                    if !profiles.active.email.isEmpty {
                        Text(profiles.active.email)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.hair)

            Button("Edit profile") { editing = profiles.active }
                .accessibilityIdentifier("editProfileButton")
        } header: {
            Text("Signed in as")
        } footer: {
            Text("Each profile keeps its own chats and its own settings, on this device.")
        }
    }

    @ViewBuilder
    private var switchSection: some View {
        // Only shown once there is somewhere to switch *to*: a "Switch profile" section with one
        // row that is already selected is a control that does nothing.
        if profiles.profiles.count > 1 {
            Section("Switch profile") {
                ForEach(profiles.profiles) { profile in
                    Button {
                        profiles.select(profile.id)
                    } label: {
                        HStack(spacing: Theme.Spacing.snug) {
                            ProfileAvatar(profile: profile, diameter: 30)
                            Text(profile.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if profile.id == profiles.activeID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityIdentifier("switchProfile-\(profile.id.uuidString)")
                }
                .onDelete(perform: delete)
            }
        }
    }

    private var addSection: some View {
        Section {
            if isAdding {
                TextField("Name", text: $addingName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("newProfileField")
                HStack {
                    Button("Add") {
                        profiles.addProfile(displayName: addingName)
                        addingName = ""
                        isAdding = false
                    }
                    .accessibilityIdentifier("confirmAddProfile")
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        addingName = ""
                        isAdding = false
                    }
                }
            } else {
                Button("Add profile") { isAdding = true }
                    .accessibilityIdentifier("addProfileButton")
            }
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign out", role: .destructive, action: auth.signOut)
                .accessibilityIdentifier("signOutButton")
        } footer: {
            Text("Signing out leaves every profile and its chats on this device.")
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            profiles.delete(profiles.profiles[index].id)
        }
    }
}

/// Editing one profile.
///
/// Edits a copy and commits on Save, rather than binding straight into the store: a live binding
/// would rename the profile letter by letter in the list behind the sheet, and Cancel would have
/// nothing to undo.
struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: UserProfile
    private let onSave: (UserProfile) -> Void

    init(profile: UserProfile, onSave: @escaping (UserProfile) -> Void) {
        self._draft = State(initialValue: profile)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatar(profile: draft, diameter: 72)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Name", text: $draft.displayName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("editProfileName")
                }

                Section("Email") {
                    TextField("Email", text: $draft.email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("editProfileEmail")
                }

                Section {
                    // A picker rather than a text field because the colour is the one part of the
                    // avatar the user can change without a photo library.
                    Picker("Colour", selection: $draft.avatarSeed) {
                        ForEach(UserProfile.avatarPalette.indices, id: \.self) { index in
                            Text(Self.colourNames[index]).tag(index)
                        }
                    }
                    .accessibilityIdentifier("editProfileColour")
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .accessibilityIdentifier("saveProfileButton")
                }
            }
        }
    }

    static let colourNames = ["Blue", "Indigo", "Purple", "Pink", "Orange", "Teal"]
}
