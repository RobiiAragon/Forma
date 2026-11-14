import SwiftUI

enum FormaStyle {
    static let background = Color(red: 0.055, green: 0.060, blue: 0.067)
    static let panel = Color(red: 0.095, green: 0.103, blue: 0.11)
    static let accent = Color(red: 1, green: 0.36, blue: 0.18)
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.89)
    static let muted = Color(red: 0.57, green: 0.60, blue: 0.61)
}

struct Eyebrow: View {
    var text: String
    @ScaledMetric(relativeTo: .caption) private var textSize = 10.0
    var body: some View {
        Text(text.uppercased()).font(.system(size: textSize, weight: .medium, design: .monospaced))
            .tracking(2).foregroundStyle(FormaStyle.muted)
    }
}

struct PrimaryButton: View {
    var title: String
    var symbol: String = "arrow.up.right"
    var action: () -> Void
    @ScaledMetric(relativeTo: .headline) private var textSize = 16.0
    @ScaledMetric(relativeTo: .headline) private var symbolSize = 19.0
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: textSize, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: symbol).font(.system(size: symbolSize, weight: .medium))
                    .accessibilityHidden(true)
            }.padding(20).foregroundStyle(.black).background(FormaStyle.accent, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}
