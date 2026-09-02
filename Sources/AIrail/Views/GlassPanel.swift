import SwiftUI

/// The app's frosted dark-glass surface, shared by the rail card, the drawn
/// island, and the overlay so they read the same on any wallpaper: a
/// consistent dark-grey base (so it never collapses to pure black on a dark
/// desktop), a hint of the material behind it, a soft top highlight, and a
/// fine light edge.
struct GlassPanel<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            // A dependable dark-grey base, lightly translucent — not pure black.
            .fill(Color(white: 0.15).opacity(0.82))
            .background(shape.fill(.ultraThinMaterial))
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
