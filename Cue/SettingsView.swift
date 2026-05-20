import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(CueAPI.self) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var redoing = false
    @State private var redoError: String?

    var body: some View {
        @Bindable var state = state
        let palette = state.palette

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(title: "Developer") {
                        toggleRow(
                            title: "Forced-decode wake engine",
                            subtitle: "Replace the default WhisperKit transcribe-and-regex wake-word path with a whisper-tiny CoreML forced-decode scorer (sliding-window mean log-prob over the keyword tokens). Scores the keyword phrase directly against the audio instead of round-tripping through text. Flipping this stops the current engine and starts the other.",
                            isOn: $state.forceDecodeWakeEnabled
                        )
                        Divider().background(state.palette.cardEdge).padding(.leading, 14)
                        toggleRow(
                            title: "Pause listening",
                            subtitle: "Hold the wake-word engine down even while an episode is loaded, so ambient conversation can't trigger the AI. Voice mode can still be opened manually.",
                            isOn: $state.wakePaused
                        )
                        Divider().background(state.palette.cardEdge).padding(.leading, 14)
                        toggleRow(
                            title: "Wake word tracking",
                            subtitle: state.wakeTrackingSubtitle,
                            isOn: $state.wakeTrackingEnabled
                        )
                        Divider().background(state.palette.cardEdge).padding(.leading, 14)
                        toggleRow(
                            title: "Audio levels",
                            subtitle: "Append peak amplitudes to each wake debug toast: pre-gain → post-gain (pre-clip) in dBFS, plus clip rate. Works with either wake engine. Whisper expects roughly -10 to -3 dBFS for speech. Requires wake word tracking.",
                            isOn: $state.audioLevelsDebugEnabled
                        )
                        Divider().background(state.palette.cardEdge).padding(.leading, 14)
                        toggleRow(
                            title: "AV Audio Session internals",
                            subtitle: "Show a HUD with the live AVAudioSession mode and VPIO state.",
                            isOn: $state.audioSessionDebugEnabled
                        )
                        Divider().background(state.palette.cardEdge).padding(.leading, 14)
                        actionRow(
                            title: "Redo onboarding",
                            subtitle: redoError ?? "Clear your saved name on the server and sign out so you can walk through the phone + code + name flow again. Use the bypass code 123456 to re-enter quickly.",
                            actionLabel: redoing ? "Resetting…" : "Reset",
                            destructive: redoError != nil,
                            disabled: redoing
                        ) {
                            Task { await redoOnboarding() }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.ink)
                }
            }
        }
        .preferredColorScheme(palette.statusDark ? .dark : .light)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        let palette = state.palette
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(Fonts.sans(11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(palette.inkMuted)
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                        )
                )
        }
    }

    @ViewBuilder
    private func toggleRow(title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        let palette = state.palette
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Fonts.sans(15, weight: .medium))
                    .foregroundStyle(palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Fonts.sans(12))
                        .foregroundStyle(palette.inkMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(palette.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func actionRow(
        title: String,
        subtitle: String?,
        actionLabel: String,
        destructive: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let palette = state.palette
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Fonts.sans(15, weight: .medium))
                    .foregroundStyle(palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Fonts.sans(12))
                        .foregroundStyle(destructive ? .red : palette.inkMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action: action) {
                Text(actionLabel)
                    .font(Fonts.sans(13, weight: .semibold))
                    .foregroundStyle(palette.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(disabled ? palette.subtleStrong : palette.ink))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @MainActor
    private func redoOnboarding() async {
        redoError = nil
        redoing = true
        defer { redoing = false }
        do {
            _ = try await api.updateAccount(name: "")
            api.signOut()
            dismiss()
        } catch {
            redoError = error.localizedDescription
        }
    }
}
