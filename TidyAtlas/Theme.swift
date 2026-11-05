import SwiftUI
import TidyCore
import UIKit

/// "Calm cartographer": warm paper, deep ink, one teal signal. Green = done, orange = needs attention.
enum Palette {
    static let tealUI = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.36, green: 0.82, blue: 0.80, alpha: 1)
        : UIColor(red: 0.10, green: 0.47, blue: 0.49, alpha: 1) }
    static let teal = Color(uiColor: tealUI)
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.06, green: 0.09, blue: 0.13, alpha: 1)
        : UIColor(red: 0.97, green: 0.95, blue: 0.92, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.11, green: 0.15, blue: 0.20, alpha: 1)
        : UIColor(red: 1.0, green: 0.995, blue: 0.985, alpha: 1) })
    static let tint = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.13, green: 0.25, blue: 0.27, alpha: 1)
        : UIColor(red: 0.85, green: 0.93, blue: 0.92, alpha: 1) })
}

extension Font {
    static func display(_ style: Font.TextStyle) -> Font { .system(style, design: .rounded).weight(.bold) }
}

struct CardStyle: ViewModifier {
    var fill: Color = Palette.card
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

extension View {
    func card(_ fill: Color = Palette.card) -> some View { modifier(CardStyle(fill: fill)) }
}

/// An item's cut-out photo, or its category icon.
struct ItemThumb: View {
    var file: String?
    var category: String
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let file, let img = UIImage(contentsOfFile: Storage.thumbURL(file).path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: Categories.symbol(category))
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
