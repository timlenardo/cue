#if DEBUG
import SwiftUI
import Combine
import AVFoundation

private enum Tuner {
    static let bg          = Color(hex: "0A0908")
    static let surface     = Color(hex: "1A1612")
    static let textBright  = Color(hex: "FDFCFB")
    static let textBody    = Color(hex: "D4D4D8")
    static let textFuture  = Color(hex: "A1A1AA")
    static let accent      = Color(hex: "A8D5BA")
    static let accentGlow  = Color(hex: "A8D5BA")
}

/// Interactive tuner for the voice waveform. Drive it from your own mic
/// (so you can speak into the simulator/device and see the response) or
/// from a static level. Every constant from `VoiceWaveformBarCore` is
/// surfaced as a slider — once a setting feels right, hand-port the
/// numbers back into `PlayerView.swift`.
struct WaveformDebugView: View {
    @StateObject private var mic = DebugMicMonitor()

    // Motion
    @State private var phaseRate: Double = 9.0
    @State private var levelBoost: Double = 3.5

    // Response curve — turns the raw level into the wave amplitude.
    // threshold: noise gate (below → flat). gamma: > 1 = spiky.
    @State private var threshold: Double = 0.0
    @State private var gamma: Double = 1.0
    @State private var smoothing: Double = 0.4

    // Amplitude
    @State private var amplitudeFactor: Double = 0.45

    // Wave 1 — fundamental
    @State private var w1Freq: Double = 0.03
    @State private var w1PhaseMult: Double = 1.0
    @State private var w1Weight: Double = 1.0

    // Wave 2 — mid
    @State private var w2Freq: Double = 0.07
    @State private var w2PhaseMult: Double = -1.5
    @State private var w2Weight: Double = 0.4

    // Wave 3 — high
    @State private var w3Freq: Double = 0.12
    @State private var w3PhaseMult: Double = 2.0
    @State private var w3Weight: Double = 0.15

    // Edges & glow
    @State private var edgeDampingPower: Double = 1.0
    @State private var glowRadius: Double = 10
    @State private var glowOpacity: Double = 0.8
    @State private var outerStroke: Double = 2.5
    @State private var innerStroke: Double = 1.5

    // Input source
    @State private var useLiveMic: Bool = true
    @State private var manualLevel: Double = 0.3
    @State private var activePreset: String? = "Current"

    @Environment(\.dismiss) private var dismiss

    private var displayLevel: Double {
        useLiveMic ? Double(mic.level) : manualLevel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    waveformPreview
                        .frame(height: 120)
                        .padding(.horizontal, 16)

                    presetRow

                    HStack {
                        Toggle("Live mic", isOn: $useLiveMic)
                            .toggleStyle(.switch)
                            .tint(Tuner.accent)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(String(format: "rms %.3f → lvl %.3f → amp %.3f", mic.rawRms, displayLevel, currentAmp))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Tuner.textFuture)
                    }
                    .padding(.horizontal, 16)

                    if !useLiveMic {
                        tunerGroup("Manual level") {
                            slider($manualLevel, range: 0...1, label: "level", format: "%.3f")
                        }
                    }

                    tunerGroup("Response curve") {
                        slider($threshold, range: 0...0.5, label: "threshold", format: "%.3f")
                        slider($gamma, range: 0.3...4.0, label: "gamma", format: "%.2f")
                        slider($smoothing, range: 0.05...1.0, label: "mic smoothing", format: "%.2f")
                    }

                    tunerGroup("Motion") {
                        slider($phaseRate, range: 0...30, label: "phase rate", format: "%.2f")
                        slider($levelBoost, range: 0...10, label: "level boost", format: "%.2f")
                    }

                    tunerGroup("Amplitude") {
                        slider($amplitudeFactor, range: 0.05...1.5, label: "amp factor", format: "%.3f")
                    }

                    tunerGroup("Wave 1 — fundamental") {
                        slider($w1Freq, range: 0.001...0.20, label: "freq", format: "%.4f")
                        slider($w1PhaseMult, range: -5...5, label: "phase ×", format: "%.2f")
                        slider($w1Weight, range: 0...2, label: "weight", format: "%.2f")
                    }

                    tunerGroup("Wave 2 — mid") {
                        slider($w2Freq, range: 0.001...0.30, label: "freq", format: "%.4f")
                        slider($w2PhaseMult, range: -5...5, label: "phase ×", format: "%.2f")
                        slider($w2Weight, range: 0...2, label: "weight", format: "%.2f")
                    }

                    tunerGroup("Wave 3 — high") {
                        slider($w3Freq, range: 0.001...0.50, label: "freq", format: "%.4f")
                        slider($w3PhaseMult, range: -5...5, label: "phase ×", format: "%.2f")
                        slider($w3Weight, range: 0...2, label: "weight", format: "%.2f")
                    }

                    tunerGroup("Edges & glow") {
                        slider($edgeDampingPower, range: 0.3...3.0, label: "edge power", format: "%.2f")
                        slider($glowRadius, range: 0...30, label: "glow radius", format: "%.1f")
                        slider($glowOpacity, range: 0...1, label: "glow opacity", format: "%.2f")
                        slider($outerStroke, range: 0.5...6, label: "outer stroke", format: "%.2f")
                        slider($innerStroke, range: 0...4, label: "inner stroke", format: "%.2f")
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Tuner.bg)
            .navigationTitle("Waveform Tuner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(Tuner.accent)
                }
            }
        }
        .onAppear {
            mic.alpha = Float(smoothing)
            mic.start()
        }
        .onDisappear { mic.stop() }
        .onChange(of: smoothing) { _, new in
            mic.alpha = Float(new)
        }
    }

    /// Threshold-gate, boost, gamma-curve. The shape that turns a level
    /// into a wave amplitude. Mirrors the math used in `waveformPreview`
    /// so the readout label is accurate.
    private var currentAmp: Double {
        let gated = max(0, displayLevel - threshold) / max(0.001, 1 - threshold)
        let boosted = min(1.0, gated * levelBoost)
        return pow(boosted, gamma)
    }

    private var waveformPreview: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t * phaseRate
            let gated = max(0, displayLevel - threshold) / max(0.001, 1 - threshold)
            let boosted = min(1.0, gated * levelBoost)
            let amp = pow(boosted, gamma)
            Canvas { ctx, size in
                let mid = Double(size.height) / 2
                let baseAmp = amp * Double(size.height) * amplitudeFactor
                let widthD = Double(size.width)
                var path = Path()
                let step: Double = 1.0
                var x: Double = 0
                path.move(to: CGPoint(x: 0, y: mid))
                while x <= widthD {
                    let n = x / max(widthD, 1)
                    let edgeDamping = pow(sin(n * .pi), edgeDampingPower)
                    let y1 = sin(x * w1Freq + phase * w1PhaseMult) * w1Weight
                    let y2 = sin(x * w2Freq + phase * w2PhaseMult) * w2Weight
                    let y3 = sin(x * w3Freq + phase * w3PhaseMult) * w3Weight
                    let composite = y1 + y2 + y3
                    let y = mid + composite * baseAmp * edgeDamping
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += step
                }
                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: Tuner.accentGlow.opacity(glowOpacity), radius: glowRadius))
                    layer.stroke(
                        path,
                        with: .color(Tuner.accent),
                        style: StrokeStyle(lineWidth: outerStroke, lineCap: .round, lineJoin: .round)
                    )
                }
                if innerStroke > 0 {
                    ctx.stroke(
                        path,
                        with: .color(Tuner.accent),
                        style: StrokeStyle(lineWidth: innerStroke, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func tunerGroup<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Tuner.accent.opacity(0.9))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tuner.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(WaveformPreset.all) { preset in
                    Button {
                        apply(preset)
                        activePreset = preset.name
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(
                                    activePreset == preset.name
                                        ? Tuner.accent
                                        : Tuner.surface
                                )
                            )
                            .foregroundStyle(
                                activePreset == preset.name
                                    ? Tuner.bg
                                    : Tuner.textBody
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func apply(_ p: WaveformPreset) {
        phaseRate = p.phaseRate
        levelBoost = p.levelBoost
        amplitudeFactor = p.amplitudeFactor
        threshold = p.threshold
        gamma = p.gamma
        smoothing = p.smoothing
        w1Freq = p.w1Freq; w1PhaseMult = p.w1PhaseMult; w1Weight = p.w1Weight
        w2Freq = p.w2Freq; w2PhaseMult = p.w2PhaseMult; w2Weight = p.w2Weight
        w3Freq = p.w3Freq; w3PhaseMult = p.w3PhaseMult; w3Weight = p.w3Weight
        edgeDampingPower = p.edgeDampingPower
        glowRadius = p.glowRadius
        glowOpacity = p.glowOpacity
        outerStroke = p.outerStroke
        innerStroke = p.innerStroke
    }

    @ViewBuilder
    private func slider(_ value: Binding<Double>, range: ClosedRange<Double>, label: String, format: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tuner.textBody)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
                .tint(Tuner.accent)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Tuner.textFuture)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - Presets

struct WaveformPreset: Identifiable {
    let name: String
    var id: String { name }
    let phaseRate, levelBoost, amplitudeFactor: Double
    let threshold, gamma, smoothing: Double
    let w1Freq, w1PhaseMult, w1Weight: Double
    let w2Freq, w2PhaseMult, w2Weight: Double
    let w3Freq, w3PhaseMult, w3Weight: Double
    let edgeDampingPower, glowRadius, glowOpacity: Double
    let outerStroke, innerStroke: Double

    static let all: [WaveformPreset] = [
        // Current shipping values — no curve, no gate.
        WaveformPreset(
            name: "Current",
            phaseRate: 9.0, levelBoost: 3.5, amplitudeFactor: 0.45,
            threshold: 0.0, gamma: 1.0, smoothing: 0.4,
            w1Freq: 0.03, w1PhaseMult: 1.0, w1Weight: 1.0,
            w2Freq: 0.07, w2PhaseMult: -1.5, w2Weight: 0.4,
            w3Freq: 0.12, w3PhaseMult: 2.0, w3Weight: 0.15,
            edgeDampingPower: 1.0, glowRadius: 10, glowOpacity: 0.8,
            outerStroke: 2.5, innerStroke: 1.5
        ),
        // Gate the noise floor, mild gamma. Quiet stays quiet, loud reads.
        WaveformPreset(
            name: "Spiky",
            phaseRate: 9.0, levelBoost: 3.0, amplitudeFactor: 1.193,
            threshold: 0.024, gamma: 0.85, smoothing: 0.26,
            w1Freq: 0.03, w1PhaseMult: 1.0, w1Weight: 1.0,
            w2Freq: 0.07, w2PhaseMult: -1.5, w2Weight: 0.4,
            w3Freq: 0.12, w3PhaseMult: 2.0, w3Weight: 0.15,
            edgeDampingPower: 1.0, glowRadius: 10, glowOpacity: 0.8,
            outerStroke: 2.5, innerStroke: 1.5
        ),
        // Higher gate, steeper gamma, snappier mic. Real jump on peaks.
        WaveformPreset(
            name: "Aggressive Spike",
            phaseRate: 11.0, levelBoost: 4.0, amplitudeFactor: 0.65,
            threshold: 0.08, gamma: 2.6, smoothing: 0.55,
            w1Freq: 0.03, w1PhaseMult: 1.0, w1Weight: 1.1,
            w2Freq: 0.07, w2PhaseMult: -1.5, w2Weight: 0.35,
            w3Freq: 0.13, w3PhaseMult: 2.2, w3Weight: 0.12,
            edgeDampingPower: 1.0, glowRadius: 12, glowOpacity: 0.9,
            outerStroke: 2.8, innerStroke: 1.6
        ),
        // Burst dynamics — only loud syllables really kick the wave.
        WaveformPreset(
            name: "Hyper Burst",
            phaseRate: 12.0, levelBoost: 5.0, amplitudeFactor: 0.80,
            threshold: 0.15, gamma: 3.2, smoothing: 0.6,
            w1Freq: 0.035, w1PhaseMult: 1.0, w1Weight: 1.2,
            w2Freq: 0.08, w2PhaseMult: -1.8, w2Weight: 0.35,
            w3Freq: 0.15, w3PhaseMult: 2.4, w3Weight: 0.12,
            edgeDampingPower: 1.0, glowRadius: 14, glowOpacity: 1.0,
            outerStroke: 3.0, innerStroke: 1.6
        ),
        // Opposite of spiky — gentle compression, slow tracking.
        WaveformPreset(
            name: "Mellow",
            phaseRate: 5.0, levelBoost: 2.5, amplitudeFactor: 0.40,
            threshold: 0.0, gamma: 0.7, smoothing: 0.25,
            w1Freq: 0.025, w1PhaseMult: 1.0, w1Weight: 1.0,
            w2Freq: 0.06, w2PhaseMult: -1.5, w2Weight: 0.5,
            w3Freq: 0.10, w3PhaseMult: 2.0, w3Weight: 0.2,
            edgeDampingPower: 1.3, glowRadius: 8, glowOpacity: 0.7,
            outerStroke: 2.5, innerStroke: 1.5
        ),
        // Low frequencies, big amplitude — boomy "speaker membrane" feel.
        WaveformPreset(
            name: "Chunky",
            phaseRate: 6.0, levelBoost: 3.0, amplitudeFactor: 0.70,
            threshold: 0.03, gamma: 1.8, smoothing: 0.5,
            w1Freq: 0.015, w1PhaseMult: 1.0, w1Weight: 1.2,
            w2Freq: 0.04, w2PhaseMult: -1.3, w2Weight: 0.5,
            w3Freq: 0.08, w3PhaseMult: 1.8, w3Weight: 0.2,
            edgeDampingPower: 1.2, glowRadius: 12, glowOpacity: 0.85,
            outerStroke: 3.0, innerStroke: 1.8
        ),
        // Fine high-frequency texture — fast wiggling threads.
        WaveformPreset(
            name: "Hairline",
            phaseRate: 14.0, levelBoost: 3.5, amplitudeFactor: 0.40,
            threshold: 0.03, gamma: 2.0, smoothing: 0.55,
            w1Freq: 0.06, w1PhaseMult: 1.0, w1Weight: 0.8,
            w2Freq: 0.11, w2PhaseMult: -1.7, w2Weight: 0.35,
            w3Freq: 0.18, w3PhaseMult: 2.4, w3Weight: 0.12,
            edgeDampingPower: 0.9, glowRadius: 8, glowOpacity: 0.7,
            outerStroke: 1.8, innerStroke: 1.0
        ),
        // Slow swell. Each loud syllable pumps a big sine bulge.
        WaveformPreset(
            name: "Heartbeat",
            phaseRate: 3.0, levelBoost: 3.0, amplitudeFactor: 0.85,
            threshold: 0.06, gamma: 2.4, smoothing: 0.5,
            w1Freq: 0.012, w1PhaseMult: 1.0, w1Weight: 1.3,
            w2Freq: 0.04, w2PhaseMult: -1.2, w2Weight: 0.35,
            w3Freq: 0.08, w3PhaseMult: 1.7, w3Weight: 0.10,
            edgeDampingPower: 1.5, glowRadius: 14, glowOpacity: 0.9,
            outerStroke: 2.6, innerStroke: 1.4
        ),
    ]
}

@MainActor
final class DebugMicMonitor: ObservableObject {
    @Published var level: Float = 0
    @Published var rawRms: Float = 0
    var alpha: Float = 0.4
    private var token: UUID?

    func start() {
        Task { @MainActor in
            if MicCapture.shared.permission != .granted {
                _ = await MicCapture.shared.requestPermission()
            }
            MicCapture.shared.start()
            token = MicCapture.shared.addBufferHandler { [weak self] buffer, _ in
                let rms = DebugMicMonitor.rms(buffer)
                Task { @MainActor [weak self] in
                    self?.absorb(rms)
                }
            }
        }
    }

    func stop() {
        if let token { MicCapture.shared.removeBufferHandler(token) }
        token = nil
        MicCapture.shared.stop()
    }

    @MainActor
    private func absorb(_ rms: Float) {
        rawRms = rms
        // Boost typical speech RMS (~0.01-0.15) into a usable 0-1 range,
        // then one-pole low-pass smooth — `alpha` is externally settable
        // so the debug UI can dial the responsiveness.
        let boosted = min(1.0, rms * 8.0)
        level = level + (boosted - level) * alpha
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let v = data[i]
            sum += v * v
        }
        return sqrt(sum / Float(frameLength))
    }
}
#endif
