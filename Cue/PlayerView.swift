import SwiftUI

// MARK: - Ambient palette
//
// The player has its own visual identity — dark warm-black background with a
// sage-green accent — independent of the global app palette. Hard-coded here
// so the whole file stays self-contained.

private enum Ambient {
    static let bg          = Color(hex: "0A0908")
    static let surface     = Color(hex: "1A1612")
    static let surfaceEdge = Color(hex: "2D241A")
    static let trackBase   = Color(hex: "27272A")

    static let textBright  = Color(hex: "FDFCFB")
    static let textPrimary = Color(hex: "E2E8F0")
    static let textBody    = Color(hex: "D4D4D8")
    static let textFuture  = Color(hex: "A1A1AA")
    static let textPast    = Color(hex: "71717A")

    static let accent      = Color(hex: "A8D5BA")
    static let accentGlow  = Color(hex: "A8D5BA")
}

// MARK: - Player

struct PlayerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack(alignment: .bottom) {
            Ambient.bg.ignoresSafeArea()

            // Transcript fills the screen between header and bottom controls.
            // No extra top padding: iOS safe area already reserves the status
            // bar; PlayerHeader sits directly underneath.
            VStack(spacing: 0) {
                PlayerHeader()
                TranscriptScrollView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(edges: .bottom)
            .opacity(state.voiceOpen ? 0.25 : 1)
            .allowsHitTesting(!state.voiceOpen)
            .animation(.easeInOut(duration: 0.25), value: state.voiceOpen)

            // Voice shade — sits above header/transcript so the upper UI
            // reads as "covered". Bottom controls strip is lifted above this
            // layer (zIndex 60) so the scrubber + play button punch through.
            if state.voiceOpen {
                VoiceAgentView()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(50)
            }

            // Bottom controls: fade region (transcript can show through here)
            // followed by a solid section that owns the progress bar, primary
            // controls, and listening pill. The solid section's bg prevents
            // transcript text from bleeding through the progress track.
            //
            // zIndex(60) keeps this strip above the voice shade so the
            // morphed scrubber + play button stay visible during voice mode.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Ambient.bg.opacity(0), Ambient.bg],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 80)
                .allowsHitTesting(false)

                VStack(spacing: 26) {
                    ProgressBar()
                    PrimaryControls()
                    ZStack {
                        SecondaryRow()
                            .opacity(state.voiceOpen ? 0.15 : 1)
                            .allowsHitTesting(!state.voiceOpen)
                        // Resume button — sits in the listening pill's slot,
                        // fades in alongside the orb/waveform when phase 2
                        // of openVoiceAgent fires (voiceMorphActive=true).
                        // Outside SecondaryRow's opacity scope so it stays
                        // at full brightness while the rest of the row dims.
                        ResumeButton { state.closeVoiceAgent() }
                            .opacity(state.voiceMorphActive ? 1 : 0)
                            .allowsHitTesting(state.voiceMorphActive)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 12)
                // Always opaque — even in voice mode — so the dimmed
                // transcript behind never bleeds through the controls.
                .background(Ambient.bg)
                .animation(.easeInOut(duration: 0.25), value: state.voiceOpen)
            }
            .zIndex(60)
        }
        // Force full-screen size regardless of when SwiftUI measures during
        // the .move(edge: .bottom) transition. Without this, the ZStack can
        // collapse to its content's intrinsic height mid-animation and the
        // bottom-alignment pins the header to the bottom of the parent.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Header

private struct PlayerHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            CircleHeaderButton(system: "chevron.down") { state.minimizePlayerAndSync() }

            VStack(spacing: 6) {
                Text(state.episodeEyebrow)
                    .font(Fonts.sans(10, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Ambient.accent.opacity(0.9))
                    .shadow(color: Ambient.accentGlow.opacity(0.35), radius: 8)
                    .lineLimit(1)
                Text(state.episodeTitle)
                    .font(.system(size: 19, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(Ambient.textBright)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 2)

            CircleHeaderButton(system: "bookmark") {}
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [Ambient.bg, Ambient.bg.opacity(0.95), Ambient.bg.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }
}

private struct CircleHeaderButton: View {
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ambient.textPrimary)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Ambient.surface)
                        .overlay(Circle().stroke(Ambient.surfaceEdge, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transcript

private struct TranscriptScrollView: View {
    @Environment(AppState.self) private var state

    @State private var followsActive: Bool = true
    @State private var scrollTopId: Int?
    @State private var didInitialScroll: Bool = false

    /// Largest index `i` such that `key(arr[i]) <= target`. Returns -1
    /// when target precedes all entries. Both transcript arrays are sorted
    /// by `start`, so this is O(log N) — versus the O(N) reverse scans
    /// this replaces, which at 10 Hz × 9000 words burned ~10 µs/sec
    /// scanning in the active-word case.
    private static func lastIndex<T>(of arr: [T], where key: (T) -> Double, leq target: Double) -> Int {
        var lo = 0, hi = arr.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if key(arr[mid]) <= target {
                ans = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return ans
    }

    var activeSentenceIdx: Int {
        let t = state.currentTime
        let sentences = state.transcriptSentences
        let i = Self.lastIndex(of: sentences, where: { $0.start }, leq: t)
        return i >= 0 ? sentences[i].id : 0
    }

    var activeWordGlobalIdx: Int {
        let t = state.currentTime
        let words = state.transcriptWords
        let i = Self.lastIndex(of: words, where: { $0.start }, leq: t)
        return i >= 0 ? words[i].globalIdx : -1
    }

    var body: some View {
        let activeIdx = activeSentenceIdx
        let activeWordIdx = activeWordGlobalIdx
        let sentences = state.transcriptSentences

        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(sentences) { sentence in
                        SentenceBlock(
                            sentence: sentence,
                            isActive: sentence.id == activeIdx,
                            isPast: sentence.id < activeIdx,
                            activeWordIdx: activeWordIdx
                        )
                        .id(sentence.id)
                    }

                    // Continuation hint.
                    Text("Transcript continues live")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Ambient.textPast.opacity(0.7))
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 320)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollTopId, anchor: UnitPoint(x: 0.5, y: 0.32))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.05),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting, didInitialScroll {
                    followsActive = false
                }
            }
            .onChange(of: activeIdx) { _, newIdx in
                guard followsActive else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollTopId = newIdx
                }
            }
            .onAppear {
                scrollTopId = activeIdx
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    didInitialScroll = true
                }
            }

            if !followsActive {
                Button {
                    followsActive = true
                    withAnimation(.easeInOut(duration: 0.35)) {
                        scrollTopId = activeIdx
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Return to playing")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Ambient.bg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Ambient.accent))
                    .shadow(color: Ambient.accentGlow.opacity(0.35), radius: 14)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: followsActive)
    }
}

private struct SentenceBlock: View {
    @Environment(AppState.self) private var state
    let sentence: TranscriptSentence
    let isActive: Bool
    let isPast: Bool
    let activeWordIdx: Int

    var body: some View {
        if isActive {
            activeCard
        } else {
            plainParagraph
        }
    }

    /// Past / future sentence — flat paragraph, muted color. Uses the
    /// pre-joined `plainText` so the per-tick body invocation doesn't have
    /// to concatenate words into an AttributedString — there's no per-word
    /// styling here, so a plain `Text(String)` is enough and the SwiftUI
    /// diff stays a no-op when `activeWordIdx` changes upstream.
    private var plainParagraph: some View {
        Text(sentence.plainText)
            .font(.system(size: 21))
            .tracking(0.4)
            .lineSpacing(8)
            .foregroundStyle(isPast ? Ambient.textPast : Ambient.textFuture)
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
            .onTapGesture { state.seek(sentence.start) }
    }

    /// Active sentence — elevated card with left green border + the
    /// currently-spoken word bolded to white.
    private var activeCard: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar (3px wide).
            Rectangle()
                .fill(Ambient.accent)
                .frame(width: 3)
                .shadow(color: Ambient.accentGlow.opacity(0.4), radius: 6)

            Text(makeAttributed())
                .font(.system(size: 21))
                .tracking(0.4)
                .lineSpacing(8)
                .foregroundStyle(Ambient.textBody)
                .multilineTextAlignment(.leading)
                // Tighter horizontal padding now that the card sits inside
                // the LazyVStack's 24pt indent (no negative outer padding).
                // Keeps text visually close to where it sits in plain-
                // paragraph mode — minimizes the active/inactive jump.
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Ambient.surface.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Ambient.surfaceEdge, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { state.seek(sentence.start) }
        .transition(.opacity)
    }

    /// Builds the AttributedString with the active word emphasized (white,
    /// semibold, soft glow). Only called from `activeCard` — inactive
    /// sentences render plain `Text(sentence.plainText)` instead.
    private func makeAttributed() -> AttributedString {
        var out = AttributedString()
        for (i, word) in sentence.words.enumerated() {
            var seg = AttributedString(word.text)
            if word.globalIdx == activeWordIdx {
                seg.foregroundColor = .white
                seg.font = .system(size: 21, weight: .semibold)
            }
            out += seg
            if i < sentence.words.count - 1 {
                out += AttributedString(" ")
            }
        }
        return out
    }
}

// MARK: - Progress

private struct ProgressBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let duration = state.totalDuration
        let pct = max(0, min(1, state.currentTime / max(duration, 1)))
        let chapter = state.currentChapter()
        // Swap visual + gesture run on `voiceMorphActive` (lags the shade)
        // so the thumb isn't bisected mid-transition. Dim/disable on the
        // surrounding row runs on `voiceOpen` (immediate, with the shade).
        let morphActive = state.voiceMorphActive
        let voiceOpen = state.voiceOpen

        VStack(spacing: 10) {
            // Track + fill + thumb (normal mode) OR track + waveform (voice mode).
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Ambient.trackBase)
                        .frame(height: 4)
                        .frame(maxHeight: .infinity, alignment: .center)

                    if morphActive {
                        VoiceWaveformBar(
                            session: state.voiceSession,
                            color: Ambient.accent,
                            glow: Ambient.accentGlow
                        )
                        .frame(height: 22)
                    } else {
                        // Opacity-gated so phase 1 of openVoiceAgent()
                        // can fade the dot + green fill out *before*
                        // morphActive flips and the waveform takes over.
                        Group {
                            Capsule()
                                .fill(Ambient.accent)
                                .frame(width: max(4, w * CGFloat(pct)), height: 4)
                                .frame(maxHeight: .infinity, alignment: .center)
                                .shadow(color: Ambient.accentGlow.opacity(0.45), radius: 8)

                            Circle()
                                .fill(.white)
                                .frame(width: 14, height: 14)
                                .shadow(color: .white.opacity(0.7), radius: 8)
                                .offset(x: w * CGFloat(pct) - 7)
                        }
                        .opacity(state.playbackDetailsVisible ? 1 : 0)
                    }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    morphActive ? nil :
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = max(0, min(1, value.location.x / w))
                            state.seek(Double(ratio) * duration)
                        }
                )
            }
            .frame(height: 22)
            .animation(.easeInOut(duration: 0.25), value: morphActive)

            // Time row with centered chapter label. Dimmed in voice mode —
            // time/chapter are irrelevant while the agent is mid-turn.
            ZStack {
                HStack {
                    Text(Format.clock(state.currentTime))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .tracking(0.4)
                        .foregroundStyle(Ambient.textPast)
                    Spacer()
                    Text("-\(Format.clock(duration - state.currentTime))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .tracking(0.4)
                        .foregroundStyle(Ambient.textPast)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(Ambient.accent)
                        .frame(width: 5, height: 5)
                        .shadow(color: Ambient.accentGlow.opacity(0.7), radius: 4)
                    Text(chapter.title)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(Ambient.textPrimary)
                        .lineLimit(1)
                }
            }
            .opacity(voiceOpen ? 0.15 : 1)
            .animation(.easeInOut(duration: 0.25), value: voiceOpen)
        }
    }
}

// MARK: - Primary controls

private struct PrimaryControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Dim/disable the surrounding controls with the shade (`voiceOpen`).
        // Swap the centre play button on the delayed `voiceMorphActive`
        // so the swap happens after the shade has covered the rest.
        let voiceOpen = state.voiceOpen
        let morphActive = state.voiceMorphActive
        HStack(spacing: 0) {
            // Speed badge — left.
            Button { state.cycleSpeed() } label: {
                Text(Speeds.label(state.speed))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Ambient.textPrimary)
                    .frame(width: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(voiceOpen ? 0.15 : 1)
            .allowsHitTesting(!voiceOpen)

            Spacer(minLength: 0)

            SkipButton(direction: .back) { state.skipBack15() }
                .opacity(voiceOpen ? 0.15 : 1)
                .allowsHitTesting(!voiceOpen)

            Spacer(minLength: 0)

            // Instant structural swap: the orb's white core takes over
            // the play button's footprint with no crossfade. Both views
            // are 88pt white discs, so the eye reads a continuous
            // surface. The halo's fade-in is handled inside VoiceOrbCore
            // via @State + onAppear so only the glow animates.
            ZStack {
                if voiceOpen {
                    VoiceOrb(session: state.voiceSession) {
                        state.closeVoiceAgent()
                    }
                    .transition(.identity)
                } else {
                    PlayButton()
                        .transition(.identity)
                }
            }

            Spacer(minLength: 0)

            SkipButton(direction: .forward) { state.skipFwd15() }
                .opacity(voiceOpen ? 0.15 : 1)
                .allowsHitTesting(!voiceOpen)

            Spacer(minLength: 0)

            // Sleep timer — right.
            Button {} label: {
                Image(systemName: "moon")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Ambient.textPrimary)
                    .frame(width: 48, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(voiceOpen ? 0.15 : 1)
            .allowsHitTesting(!voiceOpen)
        }
        .animation(.easeInOut(duration: 0.25), value: voiceOpen)
        .animation(.easeInOut(duration: 0.25), value: morphActive)
    }
}

private struct PlayButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button { state.togglePlay() } label: {
            ZStack {
                Circle()
                    .fill(Ambient.textPrimary)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Circle().stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .padding(4)
                    .background(
                        Circle()
                            .stroke(Ambient.bg, lineWidth: 4)
                    )
                    .shadow(color: .white.opacity(0.1), radius: 24)

                Image(systemName: state.iconPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Ambient.bg)
                    .offset(x: state.iconPlaying ? 0 : 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SkipButton: View {
    enum Direction { case back, forward }
    let direction: Direction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .back ? "gobackward.15" : "goforward.15")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Ambient.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Secondary row (queue + listening pill + menu)

private struct SecondaryRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack {
            Button {} label: {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Ambient.textPast)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // Suppress the .repeatForever animations while the voice agent
            // is open — SecondaryRow is dimmed to 0.15 opacity then, but
            // SwiftUI keeps animating the (mostly invisible) bars + halo
            // anyway because the animation engine doesn't see parent
            // opacity. Cuts wasted GPU cycles during voice mode.
            ListeningPill(active: state.playing && !state.voiceOpen)
                .onTapGesture { state.openVoiceAgent() }

            Spacer(minLength: 0)

            Button {} label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Ambient.textPast)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - "Cue is listening" pill

private struct ListeningPill: View {
    /// True iff the pill should run its idle `.repeatForever` motion.
    /// Combine of `state.playing && !state.voiceOpen` upstream — when the
    /// voice agent is open the pill is dimmed to 0.15 opacity but its
    /// animations were still running.
    let active: Bool
    @State private var pulse = false
    @State private var wave = false

    var body: some View {
        HStack(spacing: 12) {
            // Animated equalizer bars.
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Ambient.accent.opacity(0.8))
                        .frame(width: 3, height: barHeight(i: i))
                        .animation(
                            active
                                ? .easeInOut(duration: 1.2)
                                    .repeatForever(autoreverses: true)
                                    .delay(staggerDelay(i: i))
                                : .easeOut(duration: 0.3),
                            value: wave
                        )
                }
            }
            .frame(width: 24, height: 16)

            (Text("Tap or say ") + Text("qq").italic())
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(Ambient.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            ZStack {
                Capsule().fill(Ambient.surface.opacity(0.55))
                Capsule().stroke(Ambient.surfaceEdge, lineWidth: 1)
            }
        )
        .background(
            // Glowing orb behind the pill, offset to the top-left.
            Circle()
                .fill(Ambient.accent)
                .frame(width: 24, height: 24)
                .blur(radius: pulse ? 16 : 10)
                .scaleEffect(pulse ? 1.35 : 1.0)
                .opacity(pulse ? 0.5 : 0.25)
                .offset(x: -16, y: -10)
                .animation(
                    active
                        ? .easeInOut(duration: 4.0).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.4),
                    value: pulse
                )
                .allowsHitTesting(false)
        )
        .onAppear {
            pulse = true
            wave = true
        }
        .onChange(of: active) { _, isActive in
            // Keep animation flags live regardless; the conditional .animation
            // modifier above is what gates the actual motion.
            pulse = isActive
            wave = isActive
            // Re-arm on the next tick so .repeatForever picks up after pause.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pulse = true
                wave = true
            }
        }
    }

    private func barHeight(i: Int) -> CGFloat {
        guard active && wave else { return 5 }
        // Static seed pattern; the .repeatForever animation handles motion.
        let seeds: [CGFloat] = [12, 16, 10, 14]
        return seeds[i % seeds.count]
    }

    private func staggerDelay(i: Int) -> Double {
        [0.0, 0.2, 0.4, 0.1][i % 4]
    }
}

// MARK: - Resume button (assistant mode)

/// Sized-to-content "Resume" pill that takes over the listening-pill's
/// slot during voice-agent mode. Same capsule background, font, and
/// vertical padding as `ListeningPill`; horizontal padding kept at
/// 20pt so the touch target reads as the same shape, just narrower.
private struct ResumeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Resume")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(Ambient.textPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    ZStack {
                        Capsule().fill(Ambient.surface.opacity(0.55))
                        Capsule().stroke(Ambient.surfaceEdge, lineWidth: 1)
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Voice mode morphs
//
// Renderers that replace the play button and the scrubber-bar fill while
// the voice agent is active. Each takes an optional RealtimeVoiceSession
// so the parent can swap in/out without conditional types. Audio levels
// today come from the session's synthetic driver — see the TODOs in
// RealtimeVoiceSession for the real WebRTC metering path.

/// Voice mode replacement for the play button. Sage-green core that
/// scales with the active level (mic when listening, TTS when speaking).
/// Tap = close the voice agent and resume the podcast.
private struct VoiceOrb: View {
    let session: RealtimeVoiceSession?
    let onTap: () -> Void

    var body: some View {
        Group {
            if let session {
                VoiceOrbLive(session: session, onTap: onTap)
            } else {
                VoiceOrbCore(level: 0, onTap: onTap)
            }
        }
        .frame(width: 96, height: 96)
    }
}

private struct VoiceOrbLive: View {
    let session: RealtimeVoiceSession
    let onTap: () -> Void

    var body: some View {
        // Mic-only signal: the orb is the user's mouth, never the AI's.
        // It bounces during .listening and stays still otherwise.
        let level: Float = session.phase == .listening ? session.inputLevel : 0
        VoiceOrbCore(level: level, onTap: onTap)
    }
}

private struct VoiceOrbCore: View {
    let level: Float
    let onTap: () -> Void

    // "Galaxy" preset from the debug view, with the user-tuned overrides:
    //   - period 1.2s (faster morph rhythm)
    //   - orb rotation 20°/s (slower whole-orb spin)
    // Everything else (gain, cap, halo glow, highlight rotation, attack /
    // release) is the Galaxy default. See LiquidOrbDebug.swift if you want
    // to re-tune.
    private static let gain: Double = 4.0
    private static let cap: Double = 0.30
    private static let attackSec: Double = 0.30
    private static let releaseSec: Double = 0.60
    private static let morphPeriodSec: Double = 1.2
    private static let orbRotationDegPerSec: Double = 20
    private static let highlightRotationDegPerSec: Double = 150
    private static let haloMorphSpeedFactor: Double = -0.78
    private static let haloSize: CGFloat = 150
    private static let haloBlur: CGFloat = 24
    private static let haloOpacityBase: Double = 0.35
    private static let haloOpacityPerLevel: Double = 0.55
    private static let haloScalePerLevel: Double = 0.12
    private static let coreSize: CGFloat = 88
    private static let coreScalePerLevel: Double = 0.18

    @State private var envelope = VoiceOrbEnvelope()

    var body: some View {
        Button(action: onTap) {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let target = min(Double(level) * Self.gain, Self.cap)
                let amp = envelope.tick(
                    now: t,
                    target: target,
                    attackSec: Self.attackSec,
                    releaseSec: Self.releaseSec
                )
                liquidOrb(time: t, amp: amp)
            }
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func liquidOrb(time t: TimeInterval, amp: Double) -> some View {
        let core = blobCorners(t: t, amp: amp)
        // Halo runs the morph in reverse and slightly slower — gives the
        // outer glow its own rhythm so it never tracks the core exactly.
        let halo = blobCorners(t: t * Self.haloMorphSpeedFactor, amp: amp)

        ZStack {
            // Sage-green liquid halo behind the core.
            LiquidMorphShape(corners: halo)
                .fill(Ambient.accent)
                .frame(width: Self.haloSize, height: Self.haloSize)
                .blur(radius: Self.haloBlur)
                .opacity(Self.haloOpacityBase + Double(level) * Self.haloOpacityPerLevel)
                .scaleEffect(1.0 + CGFloat(level) * CGFloat(Self.haloScalePerLevel))

            // Core blob with rotating inner highlight.
            LiquidMorphShape(corners: core)
                .fill(Ambient.textPrimary)
                .frame(width: Self.coreSize, height: Self.coreSize)
                .overlay(
                    LiquidMorphShape(corners: core)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.95),
                                    Color.white.opacity(0)
                                ],
                                center: UnitPoint(x: 0.3, y: 0.3),
                                startRadius: 2,
                                endRadius: 70
                            )
                        )
                        .frame(width: Self.coreSize, height: Self.coreSize)
                        .rotationEffect(.degrees(t * Self.highlightRotationDegPerSec))
                )
                .scaleEffect(1.0 + CGFloat(level) * CGFloat(Self.coreScalePerLevel))
                .shadow(color: .white.opacity(0.30), radius: 22)
                .animation(.spring(response: 0.18, dampingFraction: 0.55), value: level)
        }
        // Slow rotation on the whole orb. Invisible at rest (a circle looks
        // the same at every angle), but adds a tangible sense of spin once
        // the morph kicks in.
        .rotationEffect(.degrees(t * Self.orbRotationDegPerSec))
    }

    private func blobCorners(t: TimeInterval, amp: Double) -> LiquidMorphShape.Corners {
        // Four independent oscillators — one per box edge — drive paired
        // corner radii so each edge's two radii always sum to 1.0
        // (prevents the path from crossing itself).
        let omega = (2.0 * .pi) / Self.morphPeriodSec
        let dTop    = amp * sin(omega * t + 0.0)
        let dBottom = amp * sin(omega * t + 1.7)
        let eLeft   = amp * sin(omega * t + 3.2)
        let eRight  = amp * sin(omega * t + 4.9)
        return LiquidMorphShape.Corners(
            tl: CGPoint(x: 0.5 + dTop,    y: 0.5 + eLeft),
            tr: CGPoint(x: 0.5 - dTop,    y: 0.5 + eRight),
            br: CGPoint(x: 0.5 - dBottom, y: 0.5 - eRight),
            bl: CGPoint(x: 0.5 + dBottom, y: 0.5 - eLeft)
        )
    }
}

// MARK: - Liquid morph shape

/// Square with four independently-radiused elliptical corners. Each corner
/// stores (rx, ry) as a fraction of the box width/height — the same model
/// as CSS `border-radius: A% B% C% D% / E% F% G% H%`. Oscillating those
/// values around 0.5 turns a circle into a fluid, wandering blob.
struct LiquidMorphShape: Shape {
    struct Corners: Equatable {
        var tl: CGPoint
        var tr: CGPoint
        var br: CGPoint
        var bl: CGPoint
    }
    var corners: Corners

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tl = CGPoint(x: corners.tl.x * w, y: corners.tl.y * h)
        let tr = CGPoint(x: corners.tr.x * w, y: corners.tr.y * h)
        let br = CGPoint(x: corners.br.x * w, y: corners.br.y * h)
        let bl = CGPoint(x: corners.bl.x * w, y: corners.bl.y * h)

        // Cubic Bezier approximation of a quarter ellipse.
        let k: CGFloat = 0.5522847498

        var p = Path()
        // Start at the top edge, just past the top-left corner.
        p.move(to: CGPoint(x: tl.x, y: 0))
        p.addLine(to: CGPoint(x: w - tr.x, y: 0))
        // Top-right corner.
        p.addCurve(
            to: CGPoint(x: w, y: tr.y),
            control1: CGPoint(x: w - tr.x + tr.x * k, y: 0),
            control2: CGPoint(x: w, y: tr.y - tr.y * k)
        )
        p.addLine(to: CGPoint(x: w, y: h - br.y))
        // Bottom-right corner.
        p.addCurve(
            to: CGPoint(x: w - br.x, y: h),
            control1: CGPoint(x: w, y: h - br.y + br.y * k),
            control2: CGPoint(x: w - br.x + br.x * k, y: h)
        )
        p.addLine(to: CGPoint(x: bl.x, y: h))
        // Bottom-left corner.
        p.addCurve(
            to: CGPoint(x: 0, y: h - bl.y),
            control1: CGPoint(x: bl.x - bl.x * k, y: h),
            control2: CGPoint(x: 0, y: h - bl.y + bl.y * k)
        )
        p.addLine(to: CGPoint(x: 0, y: tl.y))
        // Top-left corner.
        p.addCurve(
            to: CGPoint(x: tl.x, y: 0),
            control1: CGPoint(x: 0, y: tl.y - tl.y * k),
            control2: CGPoint(x: tl.x - tl.x * k, y: 0)
        )
        p.closeSubpath()
        return p
    }
}

/// Voice mode replacement for the scrubber's green fill. Oscilloscope-
/// style sine wave that fills the bar width, amplitude tied to the
/// session's active level. Drawn through `TimelineView(.animation)` so
/// it self-animates without external state.
private struct VoiceWaveformBar: View {
    let session: RealtimeVoiceSession?
    let color: Color
    let glow: Color

    var body: some View {
        if let session {
            VoiceWaveformBarLive(session: session, color: color, glow: glow)
        } else {
            VoiceWaveformBarCore(active: false, level: 0, color: color, glow: glow)
        }
    }
}

private struct VoiceWaveformBarLive: View {
    let session: RealtimeVoiceSession
    let color: Color
    let glow: Color

    var body: some View {
        // Activate only when the assistant is actually speaking AND the
        // WebRTC receiver is delivering non-trivial audio. The threshold
        // filters out idle hiss between turns.
        let active = session.phase == .speaking && session.outputLevel > 0.02
        VoiceWaveformBarCore(
            active: active,
            level: active ? session.outputLevel : 0,
            color: color,
            glow: glow
        )
    }
}

private struct VoiceWaveformBarCore: View {
    let active: Bool
    let level: Float
    let color: Color
    let glow: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let mid = size.height / 2
                let baseAmp = CGFloat(level) * size.height * 0.45
                // Carrier frequency in cycles across the bar width. Higher =
                // finer waveform; lower = chunkier "speaker membrane" feel.
                let cycles = 6.0
                var path = Path()
                path.move(to: CGPoint(x: 0, y: mid))
                let step: CGFloat = 1.5
                var x: CGFloat = 0
                while x <= size.width {
                    let n = x / max(size.width, 1)
                    // Envelope tethers the wave at both ends — amplitude is
                    // 0 at x=0 and x=width, peaks at the midpoint. Reads as
                    // a vibrating string anchored to the scrubber endpoints.
                    let envelope = sin(n * .pi)
                    let y = mid + sin(n * cycles * 2 * .pi + t * 6.0) * baseAmp * envelope
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += step
                }
                ctx.addFilter(.shadow(color: glow.opacity(0.45), radius: 6))
                ctx.stroke(path, with: .color(color), lineWidth: 2)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: active)
        .allowsHitTesting(false)
    }
}

// MARK: - Voice-orb envelope
//
// Smooths the audio-driven morph amplitude with separate attack and release
// time constants, ticked each frame from the TimelineView. Reference type so
// we can mutate it during render without telling SwiftUI — TimelineView is
// already scheduling redraws.

final class VoiceOrbEnvelope {
    var amp: Double = 0
    private var lastTickAt: TimeInterval = 0

    func tick(now: TimeInterval, target: Double, attackSec: Double, releaseSec: Double) -> Double {
        defer { lastTickAt = now }
        guard lastTickAt > 0 else { return amp }
        let dt = max(0, now - lastTickAt)
        let tau = target > amp ? attackSec : releaseSec
        guard tau > 0.001 else { amp = target; return amp }
        let alpha = 1.0 - exp(-dt / tau)
        amp = amp + (target - amp) * alpha
        return amp
    }
}
