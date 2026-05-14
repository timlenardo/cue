import SwiftUI
import AVFAudio

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(CueAPI.self) private var api

    var body: some View {
        @Bindable var state = state
        let palette = state.palette

        ZStack {
            palette.bg.ignoresSafeArea()

            // Main tab content.
            Group {
                switch state.tab {
                case .listen:  EntryView()
                case .library: LibraryView()
                case .notes:   NotesView()
                }
            }

            // Mini player + tab bar at the bottom. Mini player is visible
            // whenever an episode is loaded and the full player isn't open.
            VStack(spacing: 0) {
                Spacer()
                if state.live != nil && !state.playerOpen {
                    MiniPlayerBar()
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBarView()
            }

            // Player sheet — overlays everything when an episode is loaded.
            if state.playerOpen {
                PlayerView()
                    .transition(.move(edge: .bottom))
                    .zIndex(30)
            }

            // Dev wake-word transcript toasts. Above everything (including
            // the player). Non-interactive so it never blocks taps.
            WakeTranscriptOverlay()
                .allowsHitTesting(false)
                .zIndex(40)

            // Dev AVAudioSession HUD — top-leading so it doesn't collide
            // with the wake toasts at center. Polls every 0.5s.
            if state.audioSessionDebugEnabled {
                AudioSessionDebugHUD()
                    .allowsHitTesting(false)
                    .zIndex(41)
            }
        }
        .animation(.easeOut(duration: 0.28), value: state.tab)
        .animation(.easeOut(duration: 0.28), value: state.playerOpen)
        .animation(.easeOut(duration: 0.22), value: state.live != nil)
        .sheet(isPresented: $state.settingsOpen) {
            SettingsView().environment(state)
        }
        .sheet(isPresented: $state.profileOpen) {
            ProfileView().environment(state)
        }
    }
}

// MARK: - Wake-word transcript toast overlay

private struct WakeTranscriptOverlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 8) {
            ForEach(state.wakeTranscripts) { toast in
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text(toast.text)
                            .font(Fonts.sans(14, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        if toast.isHit {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(hex: "34C759"))
                        }
                    }
                    if state.audioLevelsDebugEnabled, let levels = toast.levels {
                        Self.levelsView(levels)
                            .font(Fonts.mono(11, weight: .medium))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.black.opacity(0.6))
                )
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.2), value: state.wakeTranscripts)
    }

    /// Render the level snapshot as a compact one-line subtitle:
    ///   `in: -22 → -8 dB · clip 0.0%`
    /// Pre-gain dBFS on the left of the arrow, post-gain pre-clip dBFS on
    /// the right. Healthy target for post-gain is roughly -10 to -3 dB
    /// (Whisper's training distribution); clip rate should stay near 0.
    ///
    /// Only the post-gain number is colored — that's the one that needs
    /// to land in Whisper's distribution. The pre-gain is informational
    /// (what VPIO gave us), and the clip rate is already self-explanatory
    /// at 0.0% vs anything non-zero.
    private static func levelsView(_ l: AudioLevelStats) -> Text {
        let pre = Int(l.preGainDBFS.rounded())
        let post = Int(l.postGainDBFS.rounded())
        let clipPct = l.clipRate * 100
        // %+d emits an explicit "+" for positive numbers — useful here
        // because post-gain >0 dBFS is the "you're clipping" signal.
        let neutral = Color.white.opacity(0.85)
        return Text(String(format: "in: %+d → ", pre)).foregroundStyle(neutral)
            + Text(String(format: "%+d dB", post)).foregroundStyle(postGainColor(l.postGainDBFS))
            + Text(String(format: " · clip %.1f%%", clipPct)).foregroundStyle(neutral)
    }

    /// Color the post-gain dBFS reading based on how it sits relative to
    /// Whisper's training distribution. Hand-picked sRGB hex values rather
    /// than `.green/.yellow/.red` so the colors stay legible against the
    /// black toast background regardless of the user's accent color.
    ///
    /// Thresholds:
    ///   green     -10 dB ≤ post ≤ -3 dB    (ideal — Whisper's distribution)
    ///   yellow    -15 to -10, or -3 to 0   (workable but drifting)
    ///   red       < -15 (too quiet), or > 0 (clipping)
    private static func postGainColor(_ dBFS: Double) -> Color {
        if dBFS > 0 || dBFS < -15 {
            return Color(hex: "FF453A")   // red
        }
        if dBFS >= -10 && dBFS <= -3 {
            return Color(hex: "32D74B")   // green
        }
        return Color(hex: "FFD60A")        // yellow
    }
}

// MARK: - AVAudioSession debug HUD

private struct AudioSessionDebugHUD: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let session = AVAudioSession.sharedInstance()
            let mode = Self.modeLabel(session.mode)
            #if os(iOS)
            let vpIntent = MicCapture.shared.isVoiceProcessingActive
            let vpLive = MicCapture.shared.isVoiceProcessingEnabledLive
            #else
            let vpIntent = false
            let vpLive = false
            #endif
            // Show live state primarily; flag when our intent flag and the
            // input node's actual state disagree — that's the bug pattern
            // we added this HUD to surface.
            let vpLabel = vpIntent == vpLive
                ? (vpLive ? "on" : "off")
                : "\(vpLive ? "on" : "off") ⚠︎ intent=\(vpIntent ? "on" : "off")"
            VStack(alignment: .leading, spacing: 2) {
                Text("mode: \(mode)")
                Text("VPIO: \(vpLabel)")
            }
            .font(Fonts.mono(11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.6))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, Geo.statusBarReserve + 4)
            .padding(.leading, 12)
        }
    }

    /// Strip the "AVAudioSessionMode" prefix off the raw mode string so the
    /// HUD reads as "voiceChat" / "spokenAudio" rather than a long Obj-C
    /// constant. Falls back to the raw value for any future mode we don't
    /// branch on explicitly.
    private static func modeLabel(_ mode: AVAudioSession.Mode) -> String {
        let raw = mode.rawValue
        let prefix = "AVAudioSessionMode"
        guard raw.hasPrefix(prefix) else { return raw }
        let stripped = raw.dropFirst(prefix.count)
        guard let first = stripped.first else { return "default" }
        return first.lowercased() + stripped.dropFirst()
    }
}

// MARK: - Coming soon empty state

struct ComingSoonView: View {
    @Environment(AppState.self) private var state
    let title: String

    var body: some View {
        let palette = state.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(Fonts.serif(28, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.ink)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(palette.inkFade)
                Text("Coming soon.")
                    .font(Fonts.serif(18, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(palette.inkMuted)
                Text("\(title) will return once we're past the prototype.")
                    .font(Fonts.sans(13))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .foregroundStyle(palette.inkFade)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
            Spacer(minLength: state.bottomDockHeight + 20)
        }
        .padding(.top, Geo.statusBarReserve)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg.ignoresSafeArea())
    }
}

// MARK: - Tab bar (3 tabs, no center + button)

struct TabBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let palette = state.palette

        HStack(alignment: .top, spacing: 0) {
            tabBtn(.listen, label: "Listen", system: "waveform")
            Spacer(minLength: 0)
            tabBtn(.library, label: "Library", system: "books.vertical")
            Spacer(minLength: 0)
            tabBtn(.notes, label: "Notes", system: "note.text")
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .frame(height: Geo.tabBarHeight)
        .background(
            LinearGradient(
                colors: [palette.bg.opacity(0), palette.bg],
                startPoint: .top,
                endPoint: .center
            )
        )
    }

    @ViewBuilder
    private func tabBtn(_ tab: Tab, label: String, system: String) -> some View {
        let palette = state.palette
        let active = state.tab == tab
        Button {
            state.tab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: system)
                    .font(.system(size: 22, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? palette.ink : palette.inkMuted)
                Text(label)
                    .font(Fonts.sans(10, weight: active ? .bold : .semibold))
                    .tracking(0.5)
                    .foregroundStyle(active ? palette.ink : palette.inkMuted)
            }
            .frame(width: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    RootView()
}
