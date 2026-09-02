import SwiftUI

/// The small capsule that says whether numbers are live, demo, stale, or broken.
struct StatusPill: View {
    let status: UsageStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(status.tint.opacity(0.16)))
            .overlay(Capsule().strokeBorder(status.tint.opacity(0.3)))
            .foregroundStyle(status == .demo ? Color.secondary : status.tint)
            .accessibilityLabel("Status: \(status.label)")
    }
}

extension UsageStatus {
    var tint: Color {
        switch self {
        case .ok: return .green
        case .demo: return .gray
        case .stale: return .orange
        case .error, .outage: return .red
        }
    }
}
