import SwiftUI

// MARK: - Params
//
// One struct that captures every dial on the liquid-morph orb. Defaults
// mirror the production VoiceOrbCore so the debug view starts from the
// shipping look; dragging sliders only affects this preview.

struct LiquidOrbParams: Equatable {
    // Morph (existing)
    var gain: Double = 5.0
    var cap: Double = 0.28
    var attackSec: Double = 0.30
    var releaseSec: Double = 0.60
    var morphPeriodSec: Double = 4.0
    var orbRotationDegPerSec: Double = 30
    var highlightRotationDegPerSec: Double = 60
    var haloMorphSpeedFactor: Double = -0.78
    var coreSize: CGFloat = 88
    var haloSize: CGFloat = 112
    var haloBlur: CGFloat = 14
    var haloOpacityBase: Double = 0.30
    var haloOpacityPerLevel: Double = 0.40
    var coreScalePerLevel: Double = 0.18
    var haloScalePerLevel: Double = 0.12

    // Orbit (new — planetary-rings renderer)
    var orbitMode: Bool = false
    var orbitRingCount: Int = 3
    var orbitTiltDegrees: Double = 65
    var orbitRingThickness: Double = 2.0
    var orbitRotationDegPerSec: Double = 30
    var orbitRingSpread: Double = 0.40
    var orbitOpacity: Double = 0.80
}

// MARK: - Presets

struct LiquidOrbPreset: Identifiable {
    let id: String
    let name: String
    let params: LiquidOrbParams

    static let library: [LiquidOrbPreset] = [
        .init(id: "default", name: "Default", params: LiquidOrbParams()),

        .init(id: "subtle", name: "Subtle", params: {
            var p = LiquidOrbParams()
            p.gain = 3.0; p.cap = 0.15
            p.morphPeriodSec = 6.0
            p.attackSec = 0.5; p.releaseSec = 1.0
            p.orbRotationDegPerSec = 10
            p.highlightRotationDegPerSec = 30
            p.haloOpacityBase = 0.20
            return p
        }()),

        .init(id: "pulse", name: "Pulse", params: {
            var p = LiquidOrbParams()
            p.gain = 8.0; p.cap = 0.40
            p.morphPeriodSec = 2.0
            p.attackSec = 0.10; p.releaseSec = 0.30
            p.orbRotationDegPerSec = 90
            p.coreScalePerLevel = 0.30
            p.haloScalePerLevel = 0.25
            return p
        }()),

        .init(id: "ocean", name: "Ocean", params: {
            var p = LiquidOrbParams()
            p.gain = 4.0; p.cap = 0.30
            p.morphPeriodSec = 8.0
            p.attackSec = 0.45; p.releaseSec = 0.90
            p.orbRotationDegPerSec = 15
            p.highlightRotationDegPerSec = 25
            p.haloBlur = 22
            p.haloOpacityBase = 0.40
            return p
        }()),

        .init(id: "lightning", name: "Lightning", params: {
            var p = LiquidOrbParams()
            p.gain = 10.0; p.cap = 0.42
            p.morphPeriodSec = 3.0
            p.attackSec = 0.05; p.releaseSec = 0.40
            p.orbRotationDegPerSec = 60
            p.haloOpacityPerLevel = 0.70
            return p
        }()),

        .init(id: "drone", name: "Drone", params: {
            var p = LiquidOrbParams()
            p.gain = 2.5; p.cap = 0.20
            p.morphPeriodSec = 10.0
            p.attackSec = 0.6; p.releaseSec = 1.5
            p.orbRotationDegPerSec = 5
            p.highlightRotationDegPerSec = 12
            p.haloSize = 160
            p.haloBlur = 26
            p.haloOpacityBase = 0.45
            return p
        }()),

        .init(id: "galaxy", name: "Galaxy", params: {
            var p = LiquidOrbParams()
            p.gain = 4.0; p.cap = 0.30
            p.morphPeriodSec = 5.0
            p.orbRotationDegPerSec = 45
            p.highlightRotationDegPerSec = 150
            p.haloSize = 150
            p.haloBlur = 24
            p.haloOpacityBase = 0.35
            p.haloOpacityPerLevel = 0.55
            return p
        }()),

        .init(id: "bubble", name: "Bubble", params: {
            var p = LiquidOrbParams()
            p.gain = 5.0; p.cap = 0.28
            p.morphPeriodSec = 2.5
            p.attackSec = 0.18; p.releaseSec = 0.45
            p.coreScalePerLevel = 0.35
            p.haloScalePerLevel = 0.30
            p.haloOpacityPerLevel = 0.55
            return p
        }()),

        // ORBIT-MODE PRESETS

        .init(id: "saturn", name: "Saturn", params: {
            var p = LiquidOrbParams()
            p.orbitMode = true
            p.orbitRingCount = 3
            p.orbitTiltDegrees = 65
            p.orbitRingThickness = 2.0
            p.orbitRotationDegPerSec = 25
            p.orbitRingSpread = 0.30
            p.orbitOpacity = 0.85
            p.coreSize = 60
            p.haloOpacityBase = 0.15
            return p
        }()),

        .init(id: "pulsar", name: "Pulsar", params: {
            var p = LiquidOrbParams()
            p.orbitMode = true
            p.orbitRingCount = 5
            p.orbitTiltDegrees = 30
            p.orbitRingThickness = 1.5
            p.orbitRotationDegPerSec = 120
            p.orbitRingSpread = 0.50
            p.orbitOpacity = 0.70
            p.coreSize = 50
            p.haloSize = 140
            p.haloOpacityBase = 0.25
            p.haloOpacityPerLevel = 0.60
            return p
        }()),
    ]
}

// MARK: - Envelope
//
// Smooths the audio-driven target amp with separate attack and release time
// constants, ticked each frame from the TimelineView. Stored in @State as a
// reference so we can mutate it during render without telling SwiftUI —
// TimelineView is already scheduling redraws.

private final class LiquidOrbEnvelope {
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

// MARK: - Configurable orb

struct LiquidOrbDebugCore: View {
    let level: Double
    let params: LiquidOrbParams

    @State private var envelope = LiquidOrbEnvelope()

    private static let accent      = Color(hex: "A8D5BA")
    private static let textPrimary = Color(hex: "E2E8F0")

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let target = min(level * params.gain, params.cap)
            let amp = envelope.tick(
                now: t,
                target: target,
                attackSec: params.attackSec,
                releaseSec: params.releaseSec
            )
            Group {
                if params.orbitMode {
                    orbitBody(time: t, amp: amp)
                } else {
                    morphBody(time: t, amp: amp)
                }
            }
        }
        .frame(
            width: max(params.haloSize, params.coreSize) + 40,
            height: max(params.haloSize, params.coreSize) + 40
        )
    }

    // MARK: Morph renderer

    @ViewBuilder
    private func morphBody(time t: TimeInterval, amp: Double) -> some View {
        let core = blobCorners(t: t, amp: amp)
        let halo = blobCorners(t: t * params.haloMorphSpeedFactor, amp: amp)

        ZStack {
            LiquidMorphShape(corners: halo)
                .fill(Self.accent)
                .frame(width: params.haloSize, height: params.haloSize)
                .blur(radius: params.haloBlur)
                .opacity(params.haloOpacityBase + level * params.haloOpacityPerLevel)
                .scaleEffect(1.0 + CGFloat(level) * CGFloat(params.haloScalePerLevel))

            LiquidMorphShape(corners: core)
                .fill(Self.textPrimary)
                .frame(width: params.coreSize, height: params.coreSize)
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
                        .frame(width: params.coreSize, height: params.coreSize)
                        .rotationEffect(.degrees(t * params.highlightRotationDegPerSec))
                )
                .scaleEffect(1.0 + CGFloat(level) * CGFloat(params.coreScalePerLevel))
                .shadow(color: .white.opacity(0.30), radius: 22)
        }
        .rotationEffect(.degrees(t * params.orbRotationDegPerSec))
    }

    private func blobCorners(t: TimeInterval, amp: Double) -> LiquidMorphShape.Corners {
        let omega = (2.0 * .pi) / max(params.morphPeriodSec, 0.1)
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

    // MARK: Orbit renderer
    //
    // Concentric tilted ellipses around a small core — reads as a planet with
    // rings viewed at an angle. Each ring rotates together so the tilt axis
    // sweeps around, giving the whole stack a tumbling-orbit feel. Audio
    // level expands the ring radii outward.

    @ViewBuilder
    private func orbitBody(time t: TimeInterval, amp: Double) -> some View {
        let count = max(1, min(8, params.orbitRingCount))
        let coreR = params.coreSize / 2
        let outerR = params.haloSize / 2
        let yScale = cos(params.orbitTiltDegrees * .pi / 180)
        let levelExpand = 1.0 + amp * params.orbitRingSpread * (1.0 / max(params.cap, 0.001))

        ZStack {
            // Halo glow — same as morph, so the orb feels unified across modes.
            Circle()
                .fill(Self.accent)
                .frame(width: params.haloSize, height: params.haloSize)
                .blur(radius: params.haloBlur)
                .opacity(params.haloOpacityBase + level * params.haloOpacityPerLevel)
                .scaleEffect(1.0 + CGFloat(level) * CGFloat(params.haloScalePerLevel))

            // Orbiting rings.
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let frac: Double = count > 1 ? Double(i) / Double(count - 1) : 0.5
                    let r = coreR + (outerR - coreR) * frac
                    let rr = r * levelExpand
                    Ellipse()
                        .stroke(
                            Self.textPrimary.opacity(params.orbitOpacity * (0.45 + 0.55 * (1 - frac))),
                            lineWidth: params.orbitRingThickness
                        )
                        .frame(width: rr * 2, height: rr * 2 * yScale)
                }
            }
            .rotationEffect(.degrees(t * params.orbitRotationDegPerSec))

            // Luminous core at the centre.
            Circle()
                .fill(Self.textPrimary)
                .frame(width: params.coreSize * 0.45, height: params.coreSize * 0.45)
                .scaleEffect(1.0 + CGFloat(level) * CGFloat(params.coreScalePerLevel))
                .shadow(color: Self.accent.opacity(0.4 + level * 0.5), radius: 14)
                .shadow(color: .white.opacity(0.3), radius: 6)
        }
    }
}

// MARK: - Debug screen

struct LiquidOrbDebugView: View {
    @EnvironmentObject var state: AppState
    @State private var params = LiquidOrbParams()
    @State private var selectedPresetID: String? = "default"
    @State private var manualLevel: Double = 0.0
    @State private var useLiveMic: Bool = true
    @Environment(\.dismiss) private var dismiss

    private let bg       = Color(hex: "0A0908")
    private let surface  = Color(hex: "1A1612")
    private let ink      = Color(hex: "E2E8F0")
    private let inkMuted = Color(hex: "71717A")
    private let accent   = Color(hex: "A8D5BA")

    private var liveAvailable: Bool { state.voiceSession != nil }
    private var liveActive: Bool { liveAvailable && useLiveMic }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pinnedHeader

                Divider().background(ink.opacity(0.08))

                ScrollView {
                    VStack(spacing: 22) {
                        section("Audio source") {
                            Toggle(isOn: $useLiveMic) {
                                HStack(spacing: 8) {
                                    Image(systemName: liveActive ? "mic.fill" : "mic.slash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(liveActive ? accent : inkMuted)
                                    Text("Use live mic")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ink)
                                }
                            }
                            .tint(accent)
                            .disabled(!liveAvailable)

                            if !liveAvailable {
                                Text("No active voice session. Open the player and start voice mode to feed real mic input — the session persists when you come back here.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !liveActive {
                                sliderRow("Manual level", value: $manualLevel, range: 0...0.5, format: "%.2f")
                            }
                        }

                        section("Render mode") {
                            Toggle(isOn: Binding(
                                get: { params.orbitMode },
                                set: { params.orbitMode = $0; selectedPresetID = nil }
                            )) {
                                HStack(spacing: 8) {
                                    Image(systemName: params.orbitMode ? "circle.dotted" : "drop.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(accent)
                                    Text(params.orbitMode ? "Orbit (planetary rings)" : "Liquid morph")
                                        .font(.system(size: 13))
                                        .foregroundStyle(ink)
                                }
                            }
                            .tint(accent)
                        }

                        section("Audio response") {
                            sliderRow("Gain",        value: bindParam(\.gain),       range: 0.5...20.0, format: "%.2f")
                            sliderRow("Cap",         value: bindParam(\.cap),        range: 0.05...0.50, format: "%.2f")
                            sliderRow("Attack (s)",  value: bindParam(\.attackSec),  range: 0.0...1.5,  format: "%.2f")
                            sliderRow("Release (s)", value: bindParam(\.releaseSec), range: 0.0...2.0,  format: "%.2f")
                        }

                        if params.orbitMode {
                            section("Orbit") {
                                intSliderRow("Ring count", value: bindParam(\.orbitRingCount), range: 1...8)
                                sliderRow("Tilt (°)",          value: bindParam(\.orbitTiltDegrees),      range: 0...90,   format: "%.0f")
                                sliderRow("Ring thickness",    value: bindParam(\.orbitRingThickness),    range: 0.5...8.0, format: "%.1f")
                                sliderRow("Rotation (°/s)",    value: bindParam(\.orbitRotationDegPerSec), range: -180...180, format: "%.0f")
                                sliderRow("Spread per level",  value: bindParam(\.orbitRingSpread),       range: 0.0...1.5, format: "%.2f")
                                sliderRow("Ring opacity",      value: bindParam(\.orbitOpacity),          range: 0.0...1.0, format: "%.2f")
                            }
                        } else {
                            section("Morph oscillation") {
                                sliderRow("Period (s)",  value: bindParam(\.morphPeriodSec), range: 1.0...10.0, format: "%.2f")
                            }

                            section("Rotation") {
                                sliderRow("Orb (°/s)",         value: bindParam(\.orbRotationDegPerSec),       range: -180...180, format: "%.0f")
                                sliderRow("Highlight (°/s)",   value: bindParam(\.highlightRotationDegPerSec), range: -180...180, format: "%.0f")
                                sliderRow("Halo morph factor", value: bindParam(\.haloMorphSpeedFactor),       range: -2.0...2.0, format: "%.2f")
                            }
                        }

                        section("Halo") {
                            cgSliderRow("Size", value: bindParamCG(\.haloSize), range: 60...200)
                            cgSliderRow("Blur", value: bindParamCG(\.haloBlur), range: 0...40)
                            sliderRow("Opacity base",      value: bindParam(\.haloOpacityBase),     range: 0.0...1.0, format: "%.2f")
                            sliderRow("Opacity per level", value: bindParam(\.haloOpacityPerLevel), range: 0.0...1.5, format: "%.2f")
                            sliderRow("Scale per level",   value: bindParam(\.haloScalePerLevel),   range: 0.0...1.0, format: "%.2f")
                        }

                        section("Core") {
                            cgSliderRow("Size", value: bindParamCG(\.coreSize), range: 40...120)
                            sliderRow("Scale per level", value: bindParam(\.coreScalePerLevel), range: 0.0...0.5, format: "%.2f")
                        }

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
                                params = LiquidOrbParams()
                                manualLevel = 0
                                selectedPresetID = "default"
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
                        .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Liquid Orb")
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

    // MARK: - Pinned header (stays visible while sliders scroll)

    @ViewBuilder
    private var pinnedHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(surface)
                Group {
                    if let session = state.voiceSession, useLiveMic {
                        LiquidOrbDebugCore(level: Double(session.inputLevel), params: params)
                    } else {
                        LiquidOrbDebugCore(level: manualLevel, params: params)
                    }
                }
            }
            .frame(height: 220)
            .padding(.horizontal, 20)

            // Live meta — phase pill + numeric readouts. Always shown so you
            // can see exactly what level is flowing into the orb at any time.
            HStack(spacing: 10) {
                if let session = state.voiceSession {
                    LiveMetaStrip(session: session, accent: accent, ink: ink, inkMuted: inkMuted, surface: surface, useLive: useLiveMic)
                } else {
                    Text("OFFLINE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(inkMuted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().stroke(inkMuted.opacity(0.4)))
                    Text("manual \(String(format: "%.3f", manualLevel))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(inkMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 24)

            // Preset chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LiquidOrbPreset.library) { preset in
                        Button {
                            params = preset.params
                            selectedPresetID = preset.id
                        } label: {
                            let selected = selectedPresetID == preset.id
                            Text(preset.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? bg : ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(selected ? accent : surface)
                                )
                                .overlay(
                                    Capsule().stroke(selected ? Color.clear : ink.opacity(0.12), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(bg)
    }

    // MARK: - Param bindings

    private func bindParam<T>(_ keyPath: WritableKeyPath<LiquidOrbParams, T>) -> Binding<T> {
        Binding(
            get: { params[keyPath: keyPath] },
            set: { params[keyPath: keyPath] = $0; selectedPresetID = nil }
        )
    }

    private func bindParamCG(_ keyPath: WritableKeyPath<LiquidOrbParams, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { params[keyPath: keyPath] },
            set: { params[keyPath: keyPath] = $0; selectedPresetID = nil }
        )
    }

    // MARK: - Slider helpers

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
            Slider(value: value, in: range)
                .tint(accent)
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

    private func paramsAsSwift() -> String {
        """
        // Liquid orb params
        gain: \(String(format: "%.2f", params.gain))
        cap: \(String(format: "%.2f", params.cap))
        attackSec: \(String(format: "%.2f", params.attackSec))
        releaseSec: \(String(format: "%.2f", params.releaseSec))
        morphPeriodSec: \(String(format: "%.2f", params.morphPeriodSec))
        orbRotationDegPerSec: \(String(format: "%.1f", params.orbRotationDegPerSec))
        highlightRotationDegPerSec: \(String(format: "%.1f", params.highlightRotationDegPerSec))
        haloMorphSpeedFactor: \(String(format: "%.2f", params.haloMorphSpeedFactor))
        coreSize: \(String(format: "%.0f", Double(params.coreSize)))
        haloSize: \(String(format: "%.0f", Double(params.haloSize)))
        haloBlur: \(String(format: "%.0f", Double(params.haloBlur)))
        haloOpacityBase: \(String(format: "%.2f", params.haloOpacityBase))
        haloOpacityPerLevel: \(String(format: "%.2f", params.haloOpacityPerLevel))
        coreScalePerLevel: \(String(format: "%.2f", params.coreScalePerLevel))
        haloScalePerLevel: \(String(format: "%.2f", params.haloScalePerLevel))
        // Orbit
        orbitMode: \(params.orbitMode)
        orbitRingCount: \(params.orbitRingCount)
        orbitTiltDegrees: \(String(format: "%.0f", params.orbitTiltDegrees))
        orbitRingThickness: \(String(format: "%.1f", params.orbitRingThickness))
        orbitRotationDegPerSec: \(String(format: "%.1f", params.orbitRotationDegPerSec))
        orbitRingSpread: \(String(format: "%.2f", params.orbitRingSpread))
        orbitOpacity: \(String(format: "%.2f", params.orbitOpacity))
        """
    }
}

// MARK: - Live meta strip

/// Subscribes to the session and prints phase + level numbers in real time.
/// Pulled out so the @ObservedObject re-render path is isolated — the rest
/// of the debug header doesn't need to re-evaluate on every audio tick.
private struct LiveMetaStrip: View {
    @ObservedObject var session: RealtimeVoiceSession
    let accent: Color
    let ink: Color
    let inkMuted: Color
    let surface: Color
    let useLive: Bool

    var body: some View {
        let inputText  = String(format: "%.3f", session.inputLevel)
        let outputText = String(format: "%.3f", session.outputLevel)

        HStack(spacing: 10) {
            Text(session.phase.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(surface)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(accent))

            Text("in \(inputText)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(useLive ? accent : inkMuted)

            Text("out \(outputText)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(inkMuted)
        }
    }
}
