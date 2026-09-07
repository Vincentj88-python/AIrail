import SwiftUI

/// The island silhouette. Flush with the top of the screen, its top edge flares
/// to the full width with concave fillets — the way the notch melts into the
/// menu bar — then necks in to a body with convex rounded bottom corners.
/// `flare` is the horizontal room those top fillets need on each side.
struct IslandShape: Shape {
    var flare: CGFloat = 16
    var bottomRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let f = min(flare, w / 2)
        let b = min(bottomRadius, (w - 2 * f) / 2, h - f)

        var path = Path()
        // Full-width top edge, flush with the screen's top.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        // Top-right concave fillet: neck in from full width to the body.
        path.addQuadCurve(to: CGPoint(x: w - f, y: f), control: CGPoint(x: w - f, y: 0))
        // Right side down to the convex bottom.
        path.addLine(to: CGPoint(x: w - f, y: h - b))
        path.addQuadCurve(to: CGPoint(x: w - f - b, y: h), control: CGPoint(x: w - f, y: h))
        // Bottom edge.
        path.addLine(to: CGPoint(x: f + b, y: h))
        path.addQuadCurve(to: CGPoint(x: f, y: h - b), control: CGPoint(x: f, y: h))
        // Left side up to the top-left concave fillet.
        path.addLine(to: CGPoint(x: f, y: f))
        path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: f, y: 0))
        path.closeSubpath()
        return path
    }
}
