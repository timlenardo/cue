import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var state
    @Environment(CueAPI.self) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var savedFlash = false

    var body: some View {
        let palette = state.palette

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    phoneSection
                    signOutSection

                    if let msg = errorMessage {
                        Text(msg)
                            .font(Fonts.sans(12))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.bg.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.ink)
                }
            }
        }
        .preferredColorScheme(palette.statusDark ? .dark : .light)
        .task { await loadAccount() }
    }

    // MARK: - Sections

    private var nameSection: some View {
        let palette = state.palette
        return VStack(alignment: .leading, spacing: 10) {
            Text("YOUR NAME")
                .font(Fonts.sans(11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(palette.inkMuted)

            TextField("First name", text: $name)
                .font(Fonts.sans(18))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                        )
                )
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { if canSave { Task { await save() } } }

            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    if saving { ProgressView().tint(palette.bg) }
                    Text(saveLabel)
                        .font(Fonts.sans(15, weight: .semibold))
                }
                .foregroundStyle(canSave ? palette.bg : palette.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(canSave ? palette.ink : palette.subtleStrong))
            }
            .buttonStyle(.plain)
            .disabled(!canSave || saving)
        }
    }

    private var phoneSection: some View {
        let palette = state.palette
        return VStack(alignment: .leading, spacing: 10) {
            Text("PHONE NUMBER")
                .font(Fonts.sans(11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(palette.inkMuted)

            HStack(spacing: 10) {
                Text(api.account?.phoneNumber ?? "—")
                    .font(Fonts.sans(18))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkMuted)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(palette.inkFade)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.subtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                    )
            )

            Text("Phone number can't be changed.")
                .font(Fonts.sans(12))
                .foregroundStyle(palette.inkFade)
        }
    }

    private var signOutSection: some View {
        let palette = state.palette
        return Button {
            api.signOut()
            dismiss()
        } label: {
            Text("Sign out")
                .font(Fonts.sans(15, weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(palette.subtle))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        let existing = (api.account?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && trimmedName != existing
    }

    private var saveLabel: String {
        if saving { return "Saving…" }
        if savedFlash { return "Saved" }
        return "Save"
    }

    // MARK: - Actions

    @MainActor
    private func loadAccount() async {
        if let existing = api.account?.name {
            name = existing
        }
        do {
            let acct = try await api.getAccount()
            name = acct.name ?? ""
        } catch {
            // Non-fatal: we already have whatever's in `api.account`.
        }
    }

    @MainActor
    private func save() async {
        errorMessage = nil
        saving = true
        defer { saving = false }
        do {
            _ = try await api.updateAccount(name: trimmedName)
            savedFlash = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
