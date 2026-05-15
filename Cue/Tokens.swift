import SwiftUI

// MARK: - Color hex helper

extension Color {
    init(hex: String, opacity: Double = 1) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Palette

struct Palette: Equatable {
    let bg: Color
    let surface: Color
    let ink: Color
    let inkSoft: Color
    let inkMuted: Color
    let inkFade: Color
    let accent: Color
    let accentSoft: Color
    let subtle: Color
    let subtleStrong: Color
    let cardEdge: Color
    let scrimTop: Color
    let scrimBot: Color
    let statusDark: Bool

    static let paper = Palette(
        bg: Color(hex: "F4EFE3"),
        surface: Color(hex: "FBF7EC"),
        ink: Color(hex: "1F1A14"),
        inkSoft: Color(hex: "3A322A"),
        inkMuted: Color(hex: "6B6258"),
        inkFade: Color(hex: "1F1A14", opacity: 0.32),
        accent: Color(hex: "C9543A"),
        accentSoft: Color(hex: "C9543A", opacity: 0.12),
        subtle: Color(hex: "1F1A14", opacity: 0.06),
        subtleStrong: Color(hex: "1F1A14", opacity: 0.10),
        cardEdge: Color(hex: "1F1A14", opacity: 0.08),
        scrimTop: Color(hex: "F4EFE3", opacity: 0.10),
        scrimBot: Color(hex: "F4EFE3", opacity: 0.85),
        statusDark: false
    )

    static let ink = Palette(
        bg: Color(hex: "14110D"),
        surface: Color(hex: "1E1A14"),
        ink: Color(hex: "F4EFE3"),
        inkSoft: Color(hex: "D8D1C1"),
        inkMuted: Color(hex: "8E867A"),
        inkFade: Color(hex: "F4EFE3", opacity: 0.30),
        accent: Color(hex: "E08A6D"),
        accentSoft: Color(hex: "E08A6D", opacity: 0.16),
        subtle: Color(hex: "F4EFE3", opacity: 0.06),
        subtleStrong: Color(hex: "F4EFE3", opacity: 0.12),
        cardEdge: Color(hex: "F4EFE3", opacity: 0.08),
        scrimTop: Color(hex: "14110D", opacity: 0.10),
        scrimBot: Color(hex: "14110D", opacity: 0.88),
        statusDark: true
    )

    static let forest = Palette(
        bg: Color(hex: "E8EDE3"),
        surface: Color(hex: "F2F4EC"),
        ink: Color(hex: "1B201A"),
        inkSoft: Color(hex: "384032"),
        inkMuted: Color(hex: "6A7163"),
        inkFade: Color(hex: "1B201A", opacity: 0.32),
        accent: Color(hex: "3D6B3A"),
        accentSoft: Color(hex: "3D6B3A", opacity: 0.14),
        subtle: Color(hex: "1B201A", opacity: 0.06),
        subtleStrong: Color(hex: "1B201A", opacity: 0.10),
        cardEdge: Color(hex: "1B201A", opacity: 0.09),
        scrimTop: Color(hex: "E8EDE3", opacity: 0.10),
        scrimBot: Color(hex: "E8EDE3", opacity: 0.85),
        statusDark: false
    )

    /// Dark warm-black background with a sage-green accent. Matches the
    /// player's own styling so the whole app feels like one piece.
    static let ambient = Palette(
        bg: Color(hex: "0A0908"),
        surface: Color(hex: "1A1612"),
        ink: Color(hex: "E2E8F0"),
        inkSoft: Color(hex: "D4D4D8"),
        inkMuted: Color(hex: "71717A"),
        inkFade: Color(hex: "71717A", opacity: 0.6),
        accent: Color(hex: "A8D5BA"),
        accentSoft: Color(hex: "A8D5BA", opacity: 0.14),
        subtle: Color(hex: "2D241A", opacity: 0.4),
        subtleStrong: Color(hex: "27272A"),
        cardEdge: Color(hex: "2D241A"),
        scrimTop: Color(hex: "0A0908", opacity: 0.1),
        scrimBot: Color(hex: "0A0908", opacity: 0.88),
        statusDark: true
    )
}

enum PaletteName: String, CaseIterable, Identifiable {
    case ambient, paper, ink, forest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ambient: return "Ambient"
        case .paper:   return "Paper"
        case .ink:     return "Ink"
        case .forest:  return "Forest"
        }
    }
    var palette: Palette {
        switch self {
        case .ambient: return .ambient
        case .paper:   return .paper
        case .ink:     return .ink
        case .forest:  return .forest
        }
    }
}

// MARK: - Brand colors
//
// Cross-palette accents that should look identical no matter which palette
// is active. The saved-note gold is shared by the scrubber bookmark glyph,
// the inline note card on the player, and the bookmark glyph on note rows
// in the Notes tab — one source so they can't drift.

enum Brand {
    static let noteGold = Color(red: 1.0, green: 0.84, blue: 0.0)
}

// MARK: - Geometry constants

enum Geo {
    static let tabBarHeight: CGFloat = 78
    static let miniPlayerHeight: CGFloat = 60
    static let bottomDock: CGFloat = 138    // miniPlayer + tab bar
    static let statusBarReserve: CGFloat = 50
    static let transcriptFont: CGFloat = 19
}

// MARK: - Speeds

enum Speeds {
    static let values: [Double] = [1, 1.25, 1.5, 1.75, 2, 0.85]
    static func label(_ v: Double) -> String {
        // Mirror JS: `${speed}×` — integers without decimal, others with.
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(v))×"
        }
        return "\(v)×"
    }
}

// MARK: - Type helpers

enum Fonts {
    /// Source Serif 4 fallback → system serif (New York on iOS).
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
