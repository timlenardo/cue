import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = state
        let palette = state.palette

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(title: "Developer") {
                        toggleRow(
                            title: "Wake word tracking",
                            subtitle: "Show every transcript the wake-word engine picks up as a toast. Triggers (\(WakeWordEngine.userVisibleTriggers)) get a green check.",
                            isOn: $state.wakeTrackingEnabled
                        )
                        Divider().background(state.palette.cardEdge).padding(.leading, 14)
                        toggleRow(
                            title: "Audio levels",
                            subtitle: "Append peak amplitudes to each wake transcript: pre-gain → post-gain (pre-clip) in dBFS, plus clip rate. Whisper expects roughly -10 to -3 dBFS for speech. Requires wake word tracking.",
                            isOn: $state.audioLevelsDebugEnabled
                        )
                        Divider().background(state.palette.cardEdge).padding(.leading, 14)
                        toggleRow(
                            title: "AV Audio Session internals",
                            subtitle: "Show a HUD with the live AVAudioSession mode and VPIO state.",
                            isOn: $state.audioSessionDebugEnabled
                        )
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
}

#if os(iOS)
extension WakeWordEngine {
    /// Human-readable trigger list for the settings subtitle. Mirrors the
    /// regex's alternation — kept here so the UI doesn't have to scrape
    /// the pattern at runtime.
    static let userVisibleTriggers = "tangent / sidebar / orbit"
}
#endif
