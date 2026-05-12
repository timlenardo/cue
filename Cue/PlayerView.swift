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
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            Ambient.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                PlayerHeader()
                TranscriptScrollView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, Geo.statusBarReserve)
            .ignoresSafeArea(edges: .bottom)

            // Bottom controls — fades in over the transcript with a soft scrim.
            VStack(spacing: 28) {
                ProgressBar()
                PrimaryControls()
                SecondaryRow()
                Color.clear.frame(height: 6)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 30)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: Ambient.bg.opacity(0),  location: 0.0),
                        .init(color: Ambient.bg.opacity(0.95), location: 0.18),
                        .init(color: Ambient.bg.opacity(1.0), location: 0.35),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            )

            if state.voiceOpen {
                VoiceAgentView(qaIndex: state.qaIdx)
                    .id(state.qaIdx)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(50)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Header

private struct PlayerHeader: View {
    @EnvironmentObject var state: AppState

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
    @EnvironmentObject var state: AppState

    @State private var followsActive: Bool = true
    @State private var scrollTopId: Int?
    @State private var didInitialScroll: Bool = false

    var activeSentenceIdx: Int {
        let t = state.currentTime
        var idx = 0
        for s in state.transcriptSentences.reversed() where t >= s.start {
            idx = s.id
            break
        }
        return idx
    }

    var activeWordGlobalIdx: Int {
        let t = state.currentTime
        for w in state.transcriptWords.reversed() where t >= w.start { return w.globalIdx }
        return -1
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
    @EnvironmentObject var state: AppState
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

    /// Past / future sentence — flat paragraph, muted color.
    private var plainParagraph: some View {
        Text(makeAttributed())
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
                .padding(16)
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
        .padding(.horizontal, -8)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { state.seek(sentence.start) }
        .transition(.opacity)
    }

    /// Builds the AttributedString with the active word emphasized (white,
    /// semibold, soft glow) inside an active sentence.
    private func makeAttributed() -> AttributedString {
        var out = AttributedString()
        for (i, word) in sentence.words.enumerated() {
            let isCurrent = isActive && word.globalIdx == activeWordIdx
            var seg = AttributedString(word.text)
            if isCurrent {
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
    @EnvironmentObject var state: AppState

    var body: some View {
        let duration = state.totalDuration
        let pct = max(0, min(1, state.currentTime / max(duration, 1)))
        let chapter = state.currentChapter()

        VStack(spacing: 10) {
            // Track + fill + thumb.
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Ambient.trackBase)
                        .frame(height: 4)
                        .frame(maxHeight: .infinity, alignment: .center)

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
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = max(0, min(1, value.location.x / w))
                            state.seek(Double(ratio) * duration)
                        }
                )
            }
            .frame(height: 22)

            // Time row with centered chapter label.
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
        }
    }
}

// MARK: - Primary controls

private struct PrimaryControls: View {
    @EnvironmentObject var state: AppState

    var body: some View {
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

            Spacer(minLength: 0)

            SkipButton(direction: .back) { state.skipBack15() }

            Spacer(minLength: 0)

            PlayButton()

            Spacer(minLength: 0)

            SkipButton(direction: .forward) { state.skipFwd15() }

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
        }
    }
}

private struct PlayButton: View {
    @EnvironmentObject var state: AppState

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

                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Ambient.bg)
                    .offset(x: state.playing ? 0 : 2)
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
    @EnvironmentObject var state: AppState

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

            ListeningPill(playing: state.playing)
                .onTapGesture { state.openMic() }

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
    let playing: Bool
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
                            playing
                                ? .easeInOut(duration: 1.2)
                                    .repeatForever(autoreverses: true)
                                    .delay(staggerDelay(i: i))
                                : .easeOut(duration: 0.3),
                            value: wave
                        )
                }
            }
            .frame(width: 24, height: 16)

            Text(playing ? "Cue is listening\u{2026}" : "Tap to ask Cue")
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
                    playing
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
        .onChange(of: playing) { _, isPlaying in
            // Keep animation flags live regardless; the conditional .animation
            // modifier above is what gates the actual motion.
            pulse = isPlaying
            wave = isPlaying
            // Re-arm on the next tick so .repeatForever picks up after pause.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pulse = true
                wave = true
            }
        }
    }

    private func barHeight(i: Int) -> CGFloat {
        guard playing && wave else { return 5 }
        // Static seed pattern; the .repeatForever animation handles motion.
        let seeds: [CGFloat] = [12, 16, 10, 14]
        return seeds[i % seeds.count]
    }

    private func staggerDelay(i: Int) -> Double {
        [0.0, 0.2, 0.4, 0.1][i % 4]
    }
}
