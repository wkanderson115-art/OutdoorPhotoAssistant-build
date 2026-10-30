import SwiftUI

/// Quiet visual framing feedback. It shows geometry only—no score, mode name or
/// persistent instruction text on top of the camera.
struct CompositionOverlay: View {
    let showGrid: Bool
    let automaticFraming: Bool
    let subject: SubjectInfo
    let composition: String
    let locked: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if showGrid {
                    Path { path in
                        for x in [geo.size.width / 3, geo.size.width * 2 / 3] {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                        for y in [geo.size.height / 3, geo.size.height * 2 / 3] {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                    }
                    .stroke(.white.opacity(0.28), lineWidth: 1)
                }

                if automaticFraming {
                    // Always-visible framing reticle. This confirms that automatic
                    // composition is active even before Vision finds a subject.
                    Path { path in
                        let inset: CGFloat = 14
                        let length = min(28, min(geo.size.width, geo.size.height) * 0.08)
                        let maxX = geo.size.width - inset
                        let maxY = geo.size.height - inset
                        path.move(to: CGPoint(x: inset, y: inset + length)); path.addLine(to: CGPoint(x: inset, y: inset)); path.addLine(to: CGPoint(x: inset + length, y: inset))
                        path.move(to: CGPoint(x: maxX - length, y: inset)); path.addLine(to: CGPoint(x: maxX, y: inset)); path.addLine(to: CGPoint(x: maxX, y: inset + length))
                        path.move(to: CGPoint(x: inset, y: maxY - length)); path.addLine(to: CGPoint(x: inset, y: maxY)); path.addLine(to: CGPoint(x: inset + length, y: maxY))
                        path.move(to: CGPoint(x: maxX - length, y: maxY)); path.addLine(to: CGPoint(x: maxX, y: maxY)); path.addLine(to: CGPoint(x: maxX, y: maxY - length))
                    }
                    .stroke(locked ? Color.green : Color.white.opacity(0.70),
                            style: StrokeStyle(lineWidth: locked ? 2 : 1.3, lineCap: .round, lineJoin: .round))
                }

                if automaticFraming, subject.rect != .zero {
                    let rect = displayRect(subject.rect, in: geo.size)
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(locked ? Color.green : Color.white.opacity(0.82),
                                style: StrokeStyle(lineWidth: locked ? 2 : 1.4,
                                                   dash: locked ? [] : [7, 5]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Circle()
                        .fill(locked ? Color.green : Color.white)
                        .frame(width: locked ? 10 : 7, height: locked ? 10 : 7)
                        .position(targetPoint(in: geo.size))
                        .shadow(color: .black.opacity(0.45), radius: 2)
                }

                if automaticFraming, subject.rect == .zero {
                    Circle()
                        .stroke(locked ? Color.green : Color.white.opacity(0.75), lineWidth: 1.3)
                        .frame(width: 16, height: 16)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// Vision uses a bottom-left origin; SwiftUI uses a top-left origin.
    private func displayRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width,
               y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width,
               height: normalized.height * size.height)
    }

    private func targetPoint(in size: CGSize) -> CGPoint {
        if composition == "居中" || subject.type == "人物" {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let current = displayRect(subject.rect, in: size).midX
        let x = current < size.width / 2 ? size.width / 3 : size.width * 2 / 3
        return CGPoint(x: x, y: size.height / 3)
    }
}
