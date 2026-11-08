import PaperCore
import SafariServices
import SwiftUI
import UIKit

/// "Night desk": deep ink, quiet paper cards, one blue signal for work in progress, green only for done.
enum Palette {
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.48, green: 0.70, blue: 1.0, alpha: 1)
        : UIColor(red: 0.13, green: 0.39, blue: 0.78, alpha: 1) })
    static let done = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.25, green: 0.80, blue: 0.50, alpha: 1)
        : UIColor(red: 0.13, green: 0.64, blue: 0.38, alpha: 1) })
    static let gold = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.98, green: 0.78, blue: 0.35, alpha: 1)
        : UIColor(red: 0.80, green: 0.55, blue: 0.08, alpha: 1) })
    static let flame = Color(red: 0.96, green: 0.45, blue: 0.20)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let track = Color.primary.opacity(0.08)
}

extension Font {
    static func display(_ style: Font.TextStyle) -> Font { .system(style, design: .rounded).weight(.bold) }
}

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The three marks, as in Claude's task list: dashed circle, spinning arc, green tick.
/// A parent that is part-way shows how far it is instead of spinning.
struct StatusMark: View {
    let status: Status
    var fraction: Double? = nil
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            switch status {
            case .todo:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, dash: [2.4, 2.6]))
            case .inProgress:
                Circle().strokeBorder(Palette.track, lineWidth: 2.2)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: max(0.06, min(1, fraction)))
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.1)
                } else {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
                            .padding(1.1)
                    }
                }
            case .done:
                Circle().fill(Palette.done)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: status)
        .accessibilityLabel(status.label)
    }
}

struct Bar: View {
    let fraction: Double
    var height: CGFloat = 6
    var color: Color = Palette.done

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(fraction > 0 ? height : 0, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

struct Ring: View {
    let fraction: Double
    var lineWidth: CGFloat = 7
    var color: Color = Palette.done

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

/// A burst of paper confetti, drawn with Canvas for a couple of seconds.
struct Confetti: View {
    struct Piece {
        var x: Double
        var vx: Double
        var vy: Double
        var spin: Double
        var color: Color
        var w: Double
        var h: Double
    }

    @State private var start = Date()
    @State private var pieces: [Piece] = (0..<70).map { _ in
        Piece(x: Double.random(in: 0.2...0.8), vx: Double.random(in: -260...260), vy: Double.random(in: -900 ... -450),
              spin: Double.random(in: -9...9),
              color: [Palette.done, Palette.accent, Palette.gold, Palette.flame, .pink, .purple].randomElement() ?? .green,
              w: Double.random(in: 6...10), h: Double.random(in: 9...15))
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSince(start)
                let fade = max(0, 1 - t / 2.4)
                for p in pieces {
                    let x = size.width * p.x + p.vx * t
                    let y = size.height * 0.42 + p.vy * t + 0.5 * 1500 * t * t
                    var c = g
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * t))
                    c.fill(Path(CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)), with: .color(p.color.opacity(fade)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// The toast or the big banner shown after a tick.
struct CelebrationOverlay: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        ZStack {
            if let c = store.celebration {
                if c.big { Confetti().id(c.id) }
                VStack {
                    if c.big { Spacer() }
                    VStack(spacing: 4) {
                        Text(c.headline).font(.display(c.big ? .title2 : .headline))
                        Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                        if c.big { Text(c.cheer).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 18).padding(.vertical, c.big ? 16 : 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    if c.big { Spacer() } else { Spacer().frame(height: 90) }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .id(c.id)
                .task(id: c.id) {
                    try? await Task.sleep(nanoseconds: c.big ? 2_600_000_000 : 1_300_000_000)
                    withAnimation { if store.celebration?.id == c.id { store.celebration = nil } }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.celebration)
        .allowsHitTesting(false)
    }
}

/// Opens the manuscript (Firebase Manuscript Studio) in Safari's view, which keeps the Google sign-in.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

/// LaTeX reference for a manuscript object, to paste into the source.
enum LatexRef {
    static func of(_ anchor: String) -> String {
        if anchor.hasPrefix("eq:") { return "\\eqref{\(anchor)}" }
        if anchor.hasPrefix("sec-") { return "\\ref{sec:\(anchor.dropFirst(4))}" }
        return "\\ref{\(anchor)}"
    }
}
