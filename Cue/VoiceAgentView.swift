import SwiftUI
import Combine

enum VoicePhase { case listening, transcribing, thinking, responding, done }

@MainActor
final class VoiceAgentModel: ObservableObject {
    @Published var phase: VoicePhase = .listening
    @Published var qIdx: Int = 0
    @Published var aIdx: Int = 0

    let qa: SampleQA

    private var streamTimer: AnyCancellable?
    private var phaseTimer: AnyCancellable?

    init(qa: SampleQA) { self.qa = qa }

    deinit {
        streamTimer?.cancel()
        phaseTimer?.cancel()
    }

    func cancel() {
        streamTimer?.cancel(); streamTimer = nil
        phaseTimer?.cancel(); phaseTimer = nil
    }

    // MARK: - Phase machine

    func start() {
        startListening()
    }

    private func startListening() {
        phaseTimer = Just(())
            .delay(for: .milliseconds(1100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.startTranscribing() }
    }

    private func startTranscribing() {
        phase = .transcribing
        let total = qa.q.count
        streamTimer = Timer.publish(every: 0.028, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                qIdx = min(total, qIdx + 2)
                if qIdx >= total {
                    streamTimer?.cancel(); streamTimer = nil
                    phaseTimer = Just(())
                        .delay(for: .milliseconds(350), scheduler: DispatchQueue.main)
                        .sink { [weak self] _ in self?.startThinking() }
                }
            }
    }

    private func startThinking() {
        phase = .thinking
        phaseTimer = Just(())
            .delay(for: .milliseconds(850), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.startResponding() }
    }

    private func startResponding() {
        phase = .responding
        let total = qa.answerJoined.count
        streamTimer = Timer.publish(every: 0.022, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                aIdx = min(total, aIdx + 3)
                if aIdx >= total {
                    streamTimer?.cancel(); streamTimer = nil
                    phaseTimer = Just(())
                        .delay(for: .milliseconds(350), scheduler: DispatchQueue.main)
                        .sink { [weak self] _ in self?.phase = .done }
                }
            }
    }

    var questionShown: String { String(qa.q.prefix(qIdx)) }
    var answerShown: String   { String(qa.answerJoined.prefix(aIdx)) }

    var statusLabel: String {
        switch phase {
        case .listening, .transcribing: return "Listening"
        case .thinking:                 return "Thinking"
        case .responding:               return "Speaking"
        case .done:                     return "Tap to ask again"
        }
    }
}

struct VoiceAgentView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm: VoiceAgentModel

    init(qaIndex: Int) {
        let qa = SampleData.sampleQA[abs(qaIndex) % SampleData.sampleQA.count]
        _vm = StateObject(wrappedValue: VoiceAgentModel(qa: qa))
    }

    var body: some View {
        let palette = state.palette

        ZStack(alignment: .bottom) {
            // Scrim
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

            // Sheet
            VStack(alignment: .leading, spacing: 14) {
                // Top row
                HStack(alignment: .top) {
                    HStack(spacing: 10) {
                        MicHalo(phase: vm.phase, accent: palette.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("CUE")
                                .font(Fonts.sans(11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(palette.accent)
                            HStack(spacing: 4) {
                                Text(vm.statusLabel)
                                    .font(Fonts.sans(13, weight: .medium))
                                    .foregroundStyle(palette.inkMuted)
                                if vm.phase == .thinking { ThinkingDots(color: palette.inkMuted) }
                            }
                        }
                    }
                    Spacer()
                    Button { state.resumeAfterVoice() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(palette.inkMuted)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(palette.subtle))
                    }
                    .buttonStyle(.plain)
                }

                // Question
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(vm.questionShown)
                    if vm.phase == .transcribing { Caret(color: palette.accent) }
                }
                .font(Fonts.serif(22, weight: .medium))
                .tracking(-0.1)
                .lineSpacing(6)
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.leading)

                // Answer
                if vm.phase == .responding || vm.phase == .done {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(vm.answerShown)
                        if vm.phase == .responding { Caret(color: palette.accent) }
                    }
                    .font(Fonts.sans(15))
                    .lineSpacing(6)
                    .foregroundStyle(palette.inkSoft)
                    .multilineTextAlignment(.leading)
                    .transition(.opacity)
                }

                // Bottom row
                HStack {
                    HStack(spacing: 6) {
                        PausedDot(active: vm.phase != .done, accent: palette.accent)
                        Text("Podcast paused")
                            .font(Fonts.sans(12))
                            .foregroundStyle(palette.inkMuted)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if vm.phase == .done {
                            Button { state.askAgain() } label: {
                                Text("Ask another")
                                    .font(Fonts.sans(13, weight: .medium))
                                    .foregroundStyle(palette.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(palette.subtle))
                            }
                            .buttonStyle(.plain)
                        }
                        Button { state.resumeAfterVoice() } label: {
                            Text("Resume podcast")
                                .font(Fonts.sans(13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(palette.accent))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
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
            .padding(.bottom, 130)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.cancel() }
    }
}

// MARK: - Decorations

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

private struct PausedDot: View {
    let active: Bool
    let accent: Color
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: 6, height: 6)
            .opacity(active ? (pulse ? 0.4 : 1.0) : 0.4)
            .scaleEffect(active ? (pulse ? 0.75 : 1.0) : 1.0)
            .animation(active ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

private struct MicHalo: View {
    let phase: VoicePhase
    let accent: Color
    @State private var animate = false

    var active: Bool {
        phase == .listening || phase == .transcribing || phase == .responding
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
