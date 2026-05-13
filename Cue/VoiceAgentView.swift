import SwiftUI
import Combine

/// UI phase enum — derived from `RealtimeVoiceSession.Phase` so the
/// existing decoration views (`MicHalo`, `PausedDot`) don't need to
/// learn the realtime vocabulary.
enum VoicePhase { case connecting, listening, transcribing, thinking, responding, done, error }

private func uiPhase(from session: RealtimeVoiceSession.Phase) -> VoicePhase {
    switch session {
    case .idle, .connecting: return .connecting
    case .listening:         return .listening
    case .thinking:          return .thinking
    case .speaking:          return .responding
    case .ended:             return .done
    case .error:             return .error
    }
}

/// Public entry. Reads the optional session off AppState; SwiftUI can't
/// observe an optional ObservableObject directly, so when a session is
/// active we hand it to `VoiceAgentLiveBody` which observes it via
/// `@ObservedObject`. When there is no session (canned-sample mode or
/// no live episode), we render a "load an episode" placeholder.
struct VoiceAgentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let session = state.voiceSession {
            VoiceAgentLiveBody(session: session)
        } else {
            VoiceAgentEmptyBody()
        }
    }
}

// MARK: - Live body (session present)

private struct VoiceAgentLiveBody: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var session: RealtimeVoiceSession

    private var phase: VoicePhase { uiPhase(from: session.phase) }

    private var statusLabel: String {
        if let err = session.errorMessage { return "Error: \(err)" }
        switch phase {
        case .connecting:    return "Connecting…"
        case .listening:     return "Listening"
        case .transcribing:  return "Listening"
        case .thinking:      return "Thinking"
        case .responding:    return "Speaking"
        case .done:          return "Tap to ask again"
        case .error:         return "Error"
        }
    }

    var body: some View {
        let palette = state.palette
        let userText = session.userTranscript
        let assistantText = session.assistantTranscript
        let hasContent = !userText.isEmpty || !assistantText.isEmpty

        VoiceSheetScaffold(palette: palette) {
            sheetHeader(palette: palette)

            if !userText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(userText)
                    if phase == .listening { Caret(color: palette.accent) }
                }
                .font(Fonts.serif(22, weight: .medium))
                .tracking(-0.1)
                .lineSpacing(6)
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.leading)
            }

            if !assistantText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(assistantText)
                    if phase == .responding { Caret(color: palette.accent) }
                }
                .font(Fonts.sans(15))
                .lineSpacing(6)
                .foregroundStyle(palette.inkSoft)
                .multilineTextAlignment(.leading)
                .transition(.opacity)
            }

            if !hasContent {
                Text("Ask anything about \"\(state.live?.episode.title ?? "this episode")\".")
                    .font(Fonts.sans(15))
                    .foregroundStyle(palette.inkMuted)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    private func sheetHeader(palette: Palette) -> some View {
        HStack(alignment: .top) {
            HStack(spacing: 10) {
                MicHalo(phase: phase, accent: palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CUE")
                        .font(Fonts.sans(11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(palette.accent)
                    HStack(spacing: 4) {
                        Text(statusLabel)
                            .font(Fonts.sans(13, weight: .medium))
                            .foregroundStyle(palette.inkMuted)
                        if phase == .thinking { ThinkingDots(color: palette.inkMuted) }
                    }
                }
            }
            Spacer()
            CloseButton(palette: palette) { state.resumeAfterVoice() }
        }
    }

}

// MARK: - Empty body (no live episode loaded)

private struct VoiceAgentEmptyBody: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let palette = state.palette
        VoiceSheetScaffold(palette: palette) {
            HStack(alignment: .top) {
                HStack(spacing: 10) {
                    MicHalo(phase: .done, accent: palette.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CUE")
                            .font(Fonts.sans(11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(palette.accent)
                        Text("Load an episode to talk")
                            .font(Fonts.sans(13, weight: .medium))
                            .foregroundStyle(palette.inkMuted)
                    }
                }
                Spacer()
                CloseButton(palette: palette) { state.resumeAfterVoice() }
            }

            Text("Paste a podcast URL on the home screen to load a transcript, then ask Cue about it.")
                .font(Fonts.sans(15))
                .foregroundStyle(palette.inkMuted)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - Shared scaffold + decorations

private struct VoiceSheetScaffold<Content: View>: View {
    let palette: Palette
    @ViewBuilder let content: () -> Content
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: palette.scrimTop, location: 0),
                    .init(color: palette.scrimBot, location: 0.7),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { state.resumeAfterVoice() }

            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 20)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            )
            .padding(.horizontal, 12)
            // Bottom strip in PlayerView is ~240pt tall (gradient + scrubber +
            // controls + secondary row). Pushing the card above it keeps the
            // scrubber + voice orb visible without overlap.
            .padding(.bottom, 280)
        }
    }
}

private struct CloseButton: View {
    let palette: Palette
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.inkMuted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.subtle))
        }
        .buttonStyle(.plain)
    }
}

private struct Caret: View {
    let color: Color
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: 22)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
            .padding(.leading, 2)
    }
}

private struct ThinkingDots: View {
    let color: Color
    @State private var bounce = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
                    .offset(y: bounce ? -2 : 0)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: bounce
                    )
            }
        }
        .padding(.leading, 6)
        .onAppear { bounce = true }
    }
}

private struct MicHalo: View {
    let phase: VoicePhase
    let accent: Color
    @State private var animate = false

    var active: Bool {
        phase == .listening || phase == .transcribing || phase == .responding || phase == .connecting
    }

    var body: some View {
        ZStack {
            if active {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(accent, lineWidth: 1)
                        .opacity(animate ? 0 : 0.55)
                        .scaleEffect(animate ? 1.6 : 0.85)
                        .animation(
                            .easeOut(duration: 1.8)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.6),
                            value: animate
                        )
                }
            }
            ZStack {
                Circle().fill(accent)
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        }
        .frame(width: 40, height: 40)
        .onAppear { animate = true }
    }
}
