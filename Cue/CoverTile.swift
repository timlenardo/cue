import SwiftUI

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
