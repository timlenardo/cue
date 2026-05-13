import SwiftUI

/// Episode artwork tile — renders cover art from a URL when available,
/// otherwise falls back to a monogram derived from the show title.
/// Used by the Library card hero, the Up Next row, and the mini-player.
struct EpisodeArtworkView: View {
    let urlString: String?
    let fallbackTitle: String
    var size: CGFloat = 56
    var radius: CGFloat = 12

    var body: some View {
        Group {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                    switch phase {
                    case .empty:
                        monogram
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        monogram
                    @unknown default:
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }

    private var monogram: some View {
        ZStack {
            LinearGradient(
                colors: [monogramColor, monogramColor.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(EpisodeArtworkMonogram.text(from: fallbackTitle))
                .font(Fonts.serif(size * 0.36, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(.white)
        }
    }

    private var monogramColor: Color {
        EpisodeArtworkMonogram.color(from: fallbackTitle)
    }
}

/// Deterministic monogram + color from a show title. Pulled out so the
/// AsyncImage placeholder/failure branch stays visually identical to the
/// legacy monogram tiles that ship as a fallback.
enum EpisodeArtworkMonogram {
    static func text(from s: String) -> String {
        let words = s
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        if let first = words.first?.first {
            if words.count >= 2, let second = words.dropFirst().first?.first {
                return "\(first)\(second)".uppercased()
            }
            return "\(first)".uppercased()
        }
        return "?"
    }

    static func color(from s: String) -> Color {
        var h: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.32)
    }
}

/// Show monogram tile — typeset block, no real artwork.
struct CoverTile: View {
    let showKey: String
    var size: CGFloat = 56
    var radius: CGFloat = 12

    var body: some View {
        let show = SampleData.show(showKey)
        ZStack {
            LinearGradient(
                colors: [show.color, show.color.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(show.mono)
                .font(Fonts.serif(size * 0.36, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}
