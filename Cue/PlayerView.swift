import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let palette = state.palette

        ZStack(alignment: .bottom) {
            palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                PlayerHeader()
                TranscriptScrollView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, Geo.statusBarReserve)
            .ignoresSafeArea(edges: .bottom)

            // Bottom controls scrim
            VStack(spacing: 0) {
                ProgressBar()
                Controls()
                Color.clear.frame(height: 30)
            }
            .padding(.top, 8)
            .background(
                LinearGradient(
                    colors: [palette.bg.opacity(0), palette.bg.opacity(1)],
                    startPoint: .top, endPoint: .center
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
    }
}

// MARK: - Header

private struct PlayerHeader: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let palette = state.palette

        HStack(spacing: 12) {
            Button { state.minimizePlayerAndSync() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.inkMuted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(palette.subtle))
            }
            .buttonStyle(.plain)

            VStack(spacing: 1) {
                Text(state.episodeEyebrow)
                    .font(Fonts.sans(10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                Text(state.episodeTitle)
                    .font(Fonts.serif(16, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Button {} label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(palette.inkMuted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(palette.subtle))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

// MARK: - Transcript scroll

private struct TranscriptScrollView: View {
    @EnvironmentObject var state: AppState

    /// Tracks whether auto-scroll is still glued to the active sentence.
    /// Flips to false on the first interactive scroll; back to true on
    /// "Return to playing" tap.
    @State private var followsActive: Bool = true

    /// Bound to .scrollPosition. Writing to this snaps the scroll view to
    /// the target, *cancelling any in-flight deceleration*. Reading from
    /// it gives the topmost-visible (at-anchor) sentence as the user scrolls.
    @State private var scrollTopId: Int?

    /// True once .onAppear has set the initial scroll position. Used so
    /// later writes to scrollTopId from the scroll view don't get confused
    /// with our intentional jumps.
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
        let palette = state.palette
        let activeIdx = activeSentenceIdx
        let activeWordIdx = activeWordGlobalIdx
        let sentences = state.transcriptSentences

        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(sentences) { sentence in
                        SentenceBlock(
                            sentence: sentence,
                            isActive: sentence.id == activeIdx,
                            isPast: sentence.id < activeIdx,
                            isFirstFromSpeaker: isFirstFromSpeaker(sentence: sentence, in: sentences),
                            activeWordIdx: activeWordIdx
                        )
                        .id(sentence.id)
                    }

                    // "Audio continues" placeholder card.
                    Text("Transcript continues live \u{2193}")
                        .font(Fonts.mono(11))
                        .tracking(0.4)
                        .foregroundStyle(palette.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(palette.cardEdge, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        )
                        .padding(.top, 18)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 220)
                .scrollTargetLayout()
            }
            // .scrollPosition(id:) is bidirectional: the user's scroll writes
            // the at-anchor sentence id back to scrollTopId; programmatic
            // writes scroll to the target, cancelling in-flight inertia.
            .scrollPosition(id: $scrollTopId, anchor: UnitPoint(x: 0.5, y: 0.32))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .onScrollPhaseChange { _, newPhase in
                // The user touched the scroller — stop auto-following.
                // Only matters once we've done the initial scroll, otherwise
                // SwiftUI's initial layout settles count as "interacting"
                // on some iOS versions.
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
                // First appearance: jump straight to the currently active
                // sentence so the user doesn't see the cold open when they're
                // mid-episode.
                scrollTopId = activeIdx
                // Defer the "interactive scrolls now count" flag until after
                // SwiftUI has settled the initial layout.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    didInitialScroll = true
                }
            }

            // Floating "Return to playing" pill.
            if !followsActive {
                Button {
                    // Writing the binding cancels in-flight deceleration —
                    // works even if the user is still mid-flick.
                    followsActive = true
                    withAnimation(.easeInOut(duration: 0.35)) {
                        scrollTopId = activeIdx
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Return to playing")
                            .font(Fonts.sans(12, weight: .semibold))
                            .tracking(-0.1)
                    }
                    .foregroundStyle(palette.bg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(palette.ink))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: followsActive)
    }

    private func isFirstFromSpeaker(sentence: TranscriptSentence, in sentences: [TranscriptSentence]) -> Bool {
        let idx = sentence.id
        guard idx > 0, idx < sentences.count else { return idx == 0 }
        return sentences[idx - 1].speaker != sentence.speaker
    }
}

private struct SentenceBlock: View {
    @EnvironmentObject var state: AppState
    let sentence: TranscriptSentence
    let isActive: Bool
    let isPast: Bool
    let isFirstFromSpeaker: Bool
    let activeWordIdx: Int

    var body: some View {
        let palette = state.palette
        let fontSize: CGFloat = Geo.transcriptFont
        let baseColor: Color = isActive ? palette.ink : (isPast ? palette.inkFade : palette.inkMuted)

        VStack(alignment: .leading, spacing: 6) {
            if isFirstFromSpeaker {
                Text(sentence.speaker.uppercased())
                    .font(Fonts.sans(10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.inkMuted)
            }

            sentenceText(baseColor: baseColor)
                .font(Fonts.serif(fontSize))
                .tracking(-0.1)
                .lineSpacing(fontSize * 0.5)  // approx 1.5 line-height
                .padding(.horizontal, isActive ? 10 : 0)
                .padding(.vertical, isActive ? 6 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? palette.accentSoft : .clear)
                )
                .animation(.easeInOut(duration: 0.22), value: isActive)
        }
    }

    /// Builds the sentence as a single AttributedString so it lays out with word
    /// wrapping while still highlighting the active word. (Per-word taps are
    /// approximated to the sentence — tapping the sentence seeks to its start.
    /// This trades the design's per-word tap for native text wrapping.)
    private func sentenceText(baseColor: Color) -> some View {
        let palette = state.palette
        var attributed = AttributedString()
        for (i, word) in sentence.words.enumerated() {
            let isWordActive = isActive && word.globalIdx == activeWordIdx
            let isWordPast = isActive && word.globalIdx < activeWordIdx
            let color: Color
            if isActive {
                color = (isWordPast || isWordActive) ? palette.ink : palette.inkMuted
            } else {
                color = baseColor
            }
            var seg = AttributedString(word.text)
            seg.foregroundColor = color
            if isWordActive { seg.font = Fonts.serif(Geo.transcriptFont, weight: .semibold) }
            attributed += seg
            if i < sentence.words.count - 1 {
                var space = AttributedString(" ")
                space.foregroundColor = color
                attributed += space
            }
        }

        return Text(attributed)
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
            .onTapGesture {
                state.seek(sentence.start)
            }
    }
}

// MARK: - Progress

private struct ProgressBar: View {
    @EnvironmentObject var state: AppState
    @GestureState private var dragX: CGFloat? = nil

    var body: some View {
        let palette = state.palette
        let duration = state.totalDuration
        let pct = max(0, min(1, state.currentTime / max(duration, 1)))
        let chapter = state.currentChapter()

        VStack(spacing: 4) {
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(palette.subtleStrong)
                        .frame(height: 3)
                        .frame(maxHeight: .infinity, alignment: .center)

                    // Played
                    Capsule()
                        .fill(palette.ink)
                        .frame(width: w * CGFloat(pct), height: 3)
                        .frame(maxHeight: .infinity, alignment: .center)

                    // Chapter ticks
                    ForEach(state.chapters) { c in
                        Rectangle()
                            .fill(c.t <= state.currentTime ? palette.ink : palette.inkFade)
                            .opacity(0.7)
                            .frame(width: 2, height: 9)
                            .offset(x: w * CGFloat(c.t / max(duration, 1)) - 1)
                    }

                    // Thumb
                    Circle()
                        .fill(palette.ink)
                        .frame(width: 14, height: 14)
                        .offset(x: w * CGFloat(pct) - 7)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragX) { value, st, _ in
                            st = value.location.x
                        }
                        .onChanged { value in
                            let ratio = max(0, min(1, value.location.x / w))
                            state.seek(Double(ratio) * duration)
                        }
                )
            }
            .frame(height: 22)

            HStack {
                Text(Format.clock(state.currentTime))
                    .font(Fonts.sans(11))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkMuted)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(palette.accent).frame(width: 5, height: 5)
                    Text(chapter.title)
                }
                .font(Fonts.sans(11))
                .foregroundStyle(palette.inkSoft)
                .lineLimit(1)
                Spacer()
                Text("-\(Format.clock(duration - state.currentTime))")
                    .font(Fonts.sans(11))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkMuted)
            }
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Controls

private struct Controls: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let palette = state.palette

        VStack(spacing: 10) {
            HStack {
                CircleControl(size: 44) {
                    Text(Speeds.label(state.speed))
                        .font(Fonts.sans(13, weight: .bold))
                        .monospacedDigit()
                        .tracking(-0.3)
                        .foregroundStyle(palette.ink)
                } action: { state.cycleSpeed() }

                Spacer()
                CircleControl(size: 52) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(palette.ink)
                } action: { state.skipBack15() }

                Spacer()
                PlayBtn()

                Spacer()
                CircleControl(size: 52) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(palette.ink)
                } action: { state.skipFwd15() }

                Spacer()
                CircleControl(size: 44) {
                    Image(systemName: "moon")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(palette.ink)
                } action: {}
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)

            // Hero CTA row
            HStack(spacing: 10) {
                CircleControl(size: 40) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(palette.inkMuted)
                } action: {}

                Button {
                    state.openMic()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.22))
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 30, height: 30)
                        Text("Hold to ask Cue")
                            .font(Fonts.sans(13, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 16)
                    .frame(maxWidth: 240)
                    .frame(height: 42)
                    .background(Capsule().fill(palette.accent))
                    .shadow(color: palette.accent.opacity(0.4), radius: 10, y: 6)
                }
                .buttonStyle(.plain)

                CircleControl(size: 40) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(palette.inkMuted)
                } action: {}
            }
            .padding(.horizontal, 22)
        }
    }
}

private struct PlayBtn: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let palette = state.palette
        Button { state.togglePlay() } label: {
            Image(systemName: state.playing ? "pause.fill" : "play.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(palette.bg)
                .frame(width: 72, height: 72)
                .background(Circle().fill(palette.ink))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private struct CircleControl<L: View>: View {
    let size: CGFloat
    @ViewBuilder let label: () -> L
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
