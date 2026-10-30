import SwiftUI

enum OptionSymbol { case battery, lid }

/// Native macOS line symbols. State belongs to the controls, not to a morphing
/// miniature whose silhouette could become ambiguous at menu-bar scale.
struct OptionGlyph: View {
    var symbol: OptionSymbol
    var body: some View {
        Image(systemName: symbol == .lid ? "laptopcomputer" : "battery.0percent")
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 21, height: 21)
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}
