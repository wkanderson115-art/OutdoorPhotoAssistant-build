import SwiftUI

/// Figma V2 semantic tokens. System typography scales with Dynamic Type.
enum AppTheme {
    static let paper = Color(red: 245/255, green: 246/255, blue: 243/255)
    static let ink = Color(red: 17/255, green: 25/255, blue: 22/255)
    static let muted = Color(red: 114/255, green: 123/255, blue: 118/255)
    static let mint = Color(red: 103/255, green: 219/255, blue: 180/255)
    /// Darker interactive green for text, sliders and buttons on light surfaces.
    /// The regular mint remains available for filled controls and dark camera UI.
    static let actionGreen = Color(red: 18/255, green: 126/255, blue: 91/255)
    static let soft = Color(red: 227/255, green: 243/255, blue: 235/255)
    static let card = Color.white
}
struct AppActionStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.subheadline, design: .default).weight(.semibold))
            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 12).foregroundStyle(AppTheme.ink)
            .background(enabled ? (primary ? AppTheme.mint : AppTheme.soft) : Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
extension View {
    func appCard(tinted: Bool = false) -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(tinted ? AppTheme.soft : AppTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}
