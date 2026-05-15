import SwiftUI

// MARK: - Params
//
// Knobs for the LA's assistant-speaking visualizer. Mirrors the math in
// `CueLiveActivity.AssistantVisualizer` but with everything tunable —
// once a setting feels right, hand-port the numbers back into the LA.

struct BarVizParams: Equatable {
    // Bar geometry
    var barCount: Int = 5
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 3
    var baseHeight: CGFloat = 4
    var maxHeight: CGFloat = 22

    // Group geometry
    var groupCount: Int = 5
    var groupSpacing: CGFloat = 4
    /// When true, bars across groups continue the same wave; when false
    /// each group restarts its phase at bar 0 (visually choppier).
    var continuousAcrossGroups: Bool = true

    // Motion
    /// Phase advance per pushed frame. Higher = faster cycle. At 5Hz
    /// pushes (the LA's actual rate), 1.0 ≈ 1.25s per full sin cycle.
    var temporalMultiplier: Double = 1.0
    /// Phase offset between adjacent bars. Higher = steeper visual wave.
    var spatialMultiplier: Double = 0.9

    // Per-bar variance — knobs for the "out of sequence" feel the HTML
    // reference had via `animation-duration` and `animation-delay` jitter.
    /// 0…1 mixes in a stable per-bar phase offset on top of the spatial
    /// wave. 0 = perfectly synced. 1 = each bar starts at a random phase.
    var perBarPhaseRandomness: Double = 0
    /// 0…1 varies each bar's temporalMultiplier by ±this fraction.
    /// 0 = all bars at the same speed. 1 = ±100% (some bars 2× faster).
    var perBarFreqVariance: Double = 0
}

// MARK: - Presets

struct BarVizPreset: Identifiable {
    let id: String
    let name: String
    let params: BarVizParams

    static let library: [BarVizPreset] = [
        .init(id: "current", name: "Current",  params: BarVizParams()),

        .init(id: "subtle", name: "Subtle", params: {
            var p = BarVizParams()
            p.temporalMultiplier = 0.4
            p.baseHeight = 6
            p.maxHeight = 14
            return p
        }()),

        .init(id: "pulse", name: "Pulse", params: {
            var p = BarVizParams()
            p.temporalMultiplier = 1.8
            p.maxHeight = 28
            return p
        }()),

        .init(id: "equalizer", name: "EQ jitter", params: {
            var p = BarVizParams()
            p.temporalMultiplier = 1.2
            p.perBarPhaseRandomness = 0.6
            p.perBarFreqVariance = 0.5
            return p
        }()),

        .init(id: "html", name: "HTML ref", params: {
            // Match the staggered feel of the reference HTML: bars with
            // varied animation-duration (~0.8-1.5s) and animation-delay.
            var p = BarVizParams()
            p.barCount = 5
            p.groupCount = 3
            p.temporalMultiplier = 1.6
            p.perBarPhaseRandomness = 0.8
            p.perBarFreqVariance = 0.6
            p.maxHeight = 28
            p.baseHeight = 4
            return p
        }()),

        .init(id: "heartbeat", name: "Heartbeat", params: {
            var p = BarVizParams()
            p.temporalMultiplier = 0.6
            p.spatialMultiplier = 1.6
            return p
        }()),

        .init(id: "strobe", name: "Strobe", params: {
            var p = BarVizParams()
            p.temporalMultiplier = 3.5
            return p
        }()),

        .init(id: "drone", name: "Drone", params: {
            var p = BarVizParams()
            p.temporalMultiplier = 0.25
            p.baseHeight = 4
            p.maxHeight = 12
            return p
        }()),

        .init(id: "chaotic", name: "Chaotic", params: {
            var p = BarVizParams()
            p.temporalMultiplier = 1.5
            p.perBarPhaseRandomness = 1.0
            p.perBarFreqVariance = 0.9
            return p
        }()),

        .init(id: "dense", name: "Dense", params: {
            var p = BarVizParams()
            p.barCount = 8
            p.groupCount = 3
            p.temporalMultiplier = 1.2
            p.barWidth = 2
            p.barSpacing = 2
            return p
        }()),

        .init(id: "trickle", name: "Trickle", params: {
            var p = BarVizParams()
            p.barCount = 12
            p.groupCount = 1
            p.temporalMultiplier = 0.5
            p.spatialMultiplier = 0.3
            return p
        }())
    ]
}

// MARK: - Configurable visualizer

/// The actual renderer. Drop-in compatible with the LA's `AssistantVisualizer`
/// math, just parameterized. Driven by a `frame: Double` so the preview
/// can run at 60fps in-app while the LA runs at 5Hz.
struct BarVizDebugCore: View {
    let params: BarVizParams
    let frame: Double

    private static let accent = Color(hex: "A8D5BA")
    private static let accentGlow = Color(hex: "A8D5BA")

    var body: some View {
        HStack(spacing: params.groupSpacing) {
            ForEach(0..<params.groupCount, id: \.self) { g in
                HStack(alignment: .center, spacing: params.barSpacing) {
                    ForEach(0..<params.barCount, id: \.self) { i in
                        Capsule()
                            .fill(Self.accent)
                            .frame(
                                width: params.barWidth,
                                height: barHeight(groupIndex: g, barIndex: i)
                            )
                    }
                }
                .shadow(color: Self.accentGlow.opacity(0.55), radius: 6)
            }
        }
        .frame(height: params.maxHeight)
    }

    private func barHeight(groupIndex g: Int, barIndex i: Int) -> CGFloat {
        let totalIndex = g * params.barCount + i
        let spatialPhase: Double = params.continuousAcrossGroups
            ? Double(totalIndex) * params.spatialMultiplier
            : Double(i) * params.spatialMultiplier
        let randomPhase = Self.hashPhase(totalIndex) * params.perBarPhaseRandomness
        let freqMod = 1.0 + (Self.hashUnit(totalIndex + 9_973) - 0.5) * 2 * params.perBarFreqVariance
        let phase = frame * params.temporalMultiplier * freqMod + spatialPhase + randomPhase
        let n = (sin(phase) + 1) / 2  // 0…1
        return params.baseHeight + (params.maxHeight - params.baseHeight) * CGFloat(n)
    }

    // GLSL-style stable hash so per-bar offsets don't change every render
    // but DO change if you add/remove bars.
    private static func hashPhase(_ i: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + 78.233) * 43758.5453
        return (v - floor(v)) * 2 * .pi
    }

    private static func hashUnit(_ i: Int) -> Double {
        let v = sin(Double(i) * 4.367 + 19.81) * 17263.21
        return v - floor(v)
    }
}

// MARK: - Playground screen

struct WaveformPlaygroundView: View {
    @State private var params = BarVizParams()
    @State private var selectedPresetID: String? = "current"
    @State private var simulateLAPushes: Bool = false
    @Environment(\.dismiss) private var dismiss

    private let bg = Color(hex: "0A0908")
    private let surface = Color(hex: "1A1612")
    private let ink = Color(hex: "E2E8F0")
    private let inkMuted = Color(hex: "71717A")
    private let accent = Color(hex: "A8D5BA")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview

                Divider().background(ink.opacity(0.08))

                ScrollView {
                    VStack(spacing: 22) {
                        presetChips

                        section("Bars") {
                            intSliderRow("Bar count",     value: bindInt(\.barCount),    range: 1...20)
                            intSliderRow("Group count",   value: bindInt(\.groupCount),  range: 1...8)
                            cgSliderRow("Bar width",      value: bindCG(\.barWidth),     range: 1...10)
                            cgSliderRow("Bar spacing",    value: bindCG(\.barSpacing),   range: 0...10)
                            cgSliderRow("Group spacing",  value: bindCG(\.groupSpacing), range: 0...20)
                        }

                        section("Heights") {
                            cgSliderRow("Base height", value: bindCG(\.baseHeight), range: 1...20)
                            cgSliderRow("Max height",  value: bindCG(\.maxHeight),  range: 8...60)
                        }

                        section("Motion") {
                            sliderRow("Temporal multiplier", value: bind(\.temporalMultiplier), range: 0.05...5.0, format: "%.2f")
                            sliderRow("Spatial multiplier",  value: bind(\.spatialMultiplier),  range: 0.0...3.0,  format: "%.2f")
                            toggleRow("Continuous across groups", value: bindBool(\.continuousAcrossGroups))
                        }

                        section("Per-bar variance (out of sequence)") {
                            sliderRow("Phase randomness",     value: bind(\.perBarPhaseRandomness), range: 0.0...1.0, format: "%.2f")
                            sliderRow("Frequency variance",   value: bind(\.perBarFreqVariance),    range: 0.0...1.0, format: "%.2f")
                        }

                        section("Preview rate") {
                            Toggle(isOn: $simulateLAPushes) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Simulate LA push rate (5Hz)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ink)
                                    Text("On = step every 200ms (matches what the LA actually renders). Off = smooth 60fps preview.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(inkMuted)
                                }
                            }
                            .tint(accent)
                        }

                        actionButtons
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Waveform")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(ink)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        VStack(spacing: 8) {
            TimelineView(.animation) { context in
                let secs = context.date.timeIntervalSinceReferenceDate
                // Frame model: 1 frame per LA push = 200ms. At 60fps preview,
                // pass the continuous time. At 5Hz preview, snap to integers
                // so the SwiftUI implicit animation interpolates between
                // discrete steps — same as what the LA snapshot crossfade does.
                let frame: Double = simulateLAPushes
                    ? floor(secs * 5)
                    : secs * 5
                BarVizDebugCore(params: params, frame: frame)
                    .animation(simulateLAPushes ? .easeInOut(duration: 0.18) : nil, value: frame)
            }
            .frame(height: max(params.maxHeight, 28) + 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(bg)
    }

    // MARK: Preset chips

    @ViewBuilder
    private var presetChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PRESETS")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(inkMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BarVizPreset.library) { preset in
                        let selected = selectedPresetID == preset.id
                        Button {
                            params = preset.params
                            selectedPresetID = preset.id
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(selected ? accent : surface)
                                )
                                .foregroundStyle(selected ? bg : ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    // MARK: Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = paramsAsSwift()
            } label: {
                Text("Copy values")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(bg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)

            Button {
                params = BarVizParams()
                selectedPresetID = "current"
            } label: {
                Text("Reset")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().stroke(ink.opacity(0.3)))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: Bindings

    private func bind<T>(_ kp: WritableKeyPath<BarVizParams, T>) -> Binding<T> {
        Binding(
            get: { params[keyPath: kp] },
            set: { params[keyPath: kp] = $0; selectedPresetID = nil }
        )
    }

    private func bindCG(_ kp: WritableKeyPath<BarVizParams, CGFloat>) -> Binding<CGFloat> { bind(kp) }
    private func bindInt(_ kp: WritableKeyPath<BarVizParams, Int>) -> Binding<Int>       { bind(kp) }
    private func bindBool(_ kp: WritableKeyPath<BarVizParams, Bool>) -> Binding<Bool>     { bind(kp) }

    // MARK: Slider helpers (same pattern as LiquidOrbDebug)

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(inkMuted)
            VStack(spacing: 14) {
                content()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(surface))
        }
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(ink)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(accent)
            }
            Slider(value: value, in: range).tint(accent)
        }
    }

    @ViewBuilder
    private func cgSliderRow(
        _ label: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(ink)
                Spacer()
                Text(String(format: "%.0f", Double(value.wrappedValue)))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(accent)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = CGFloat($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(accent)
        }
    }

    @ViewBuilder
    private func intSliderRow(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13)).foregroundStyle(ink)
                Spacer()
                Text(String(value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(accent)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(accent)
        }
    }

    @ViewBuilder
    private func toggleRow(_ label: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(label).font(.system(size: 13)).foregroundStyle(ink)
        }
        .tint(accent)
    }

    private func paramsAsSwift() -> String {
        """
        // Waveform params
        barCount: \(params.barCount)
        barWidth: \(String(format: "%.1f", Double(params.barWidth)))
        barSpacing: \(String(format: "%.1f", Double(params.barSpacing)))
        baseHeight: \(String(format: "%.1f", Double(params.baseHeight)))
        maxHeight: \(String(format: "%.1f", Double(params.maxHeight)))
        groupCount: \(params.groupCount)
        groupSpacing: \(String(format: "%.1f", Double(params.groupSpacing)))
        continuousAcrossGroups: \(params.continuousAcrossGroups)
        temporalMultiplier: \(String(format: "%.2f", params.temporalMultiplier))
        spatialMultiplier: \(String(format: "%.2f", params.spatialMultiplier))
        perBarPhaseRandomness: \(String(format: "%.2f", params.perBarPhaseRandomness))
        perBarFreqVariance: \(String(format: "%.2f", params.perBarFreqVariance))
        """
    }
}
