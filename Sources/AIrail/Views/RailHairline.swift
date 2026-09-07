import AppKit
import SwiftUI

/// The collapsed indicator: a single calm accent line with a soft matching
/// glow, gently breathing between two intensities. Deliberately barely-there —
/// one colour, never a rainbow. Runs vertically on the edge rail, horizontally
/// under the notch.
///
/// The breath is a Core Animation opacity animation on two layers, which the
/// render server plays without any per-frame work in the process (the SwiftUI
/// timeline it replaced re-laid out the whole panel twenty times a second).
/// It holds still under Reduce Motion, Low Power Mode or serious thermal
/// pressure, and pauses while the window is occluded or the screens sleep.
struct RailHairline: NSViewRepresentable {
    var reduceMotion: Bool
    var axis: Axis = .vertical
    /// The line's colour — calm by default, warming toward the limit.
    var accent: Color = Color(hex: 0x6E8BFF)
    /// How much of the line is lit, 0…1, from the bottom on an edge and from
    /// the leading end under the notch, over a faint full-length track; nil
    /// lights the whole line with no track (no figure to show).
    var fill: Double? = nil

    func makeNSView(context: Context) -> HairlineView {
        HairlineView()
    }

    func updateNSView(_ view: HairlineView, context: Context) {
        view.apply(axis: axis, accent: NSColor(accent), fill: fill, reduceMotion: reduceMotion)
    }
}

/// Three capsule layers: a faint track the full length (only with a fill), a
/// soft glow and the line itself, the last two sized to the lit part.
final class HairlineView: NSView {
    private let track = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let line = CAShapeLayer()

    private var axis: Axis = .vertical
    private var accent = NSColor(Color(hex: 0x6E8BFF))
    private var fill: Double?
    private var reduceMotion = false
    private var screensAsleep = false
    private let observers = ObserverTokens()

    /// One way; the round trip is the 4.5 s the timeline used to take.
    private static let breath: TimeInterval = 2.25
    private static let animationKey = "breath"
    /// The intensity held when the line isn't breathing (0.85 of the way up).
    private static let heldIntensity = 0.85

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for capsule in [track, glow, line] {
            capsule.contentsScale = window?.backingScaleFactor ?? 2
            layer?.addSublayer(capsule)
        }
        glow.shadowOffset = .zero
        glow.shadowRadius = 4
        glow.shadowOpacity = 1
        line.lineWidth = 0.5
        line.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        applyColors()
        holdStill()

        // Power and thermal changes arrive on a global queue; asking for the
        // main queue keeps the layer work where it belongs.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.add(center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMotion() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.add(workspace, workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.refreshMotion()
            }
        })
        observers.add(workspace, workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = false
                self?.refreshMotion()
            }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(axis: Axis, accent: NSColor, fill: Double?, reduceMotion: Bool) {
        let colourChanged = accent != self.accent
        let shapeChanged = axis != self.axis || fill != self.fill
        self.axis = axis
        self.accent = accent
        self.fill = fill
        self.reduceMotion = reduceMotion
        if colourChanged { applyColors() }
        if shapeChanged { layoutCapsules(animated: fill != nil) }
        refreshMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.removeOcclusion()
        if let window {
            let scale = window.backingScaleFactor
            for capsule in [track, glow, line] { capsule.contentsScale = scale }
            let center = NotificationCenter.default
            observers.setOcclusion(center, center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMotion() }
            })
        }
        refreshMotion()
    }

    override func layout() {
        super.layout()
        layoutCapsules(animated: false)
    }

    // MARK: Shape

    /// A fill change eases over 0.6 s; a resize doesn't animate at all.
    private func layoutCapsules(animated: Bool) {
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        for capsule in [track, glow, line] { capsule.frame = bounds }
        let lit = fill.map { max(0.08, min(1, $0)) } ?? 1
        let trackPath = capsulePath(fraction: 1, width: 3, in: bounds)
        let linePath = capsulePath(fraction: lit, width: 3, in: bounds)
        let glowPath = capsulePath(fraction: lit, width: 5, in: bounds)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = trackPath
        track.isHidden = fill == nil
        if animated, let from = line.presentation()?.path ?? line.path {
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            let lineMove = CABasicAnimation(keyPath: "path")
            lineMove.fromValue = from
            lineMove.duration = 0.6
            lineMove.timingFunction = ease
            line.add(lineMove, forKey: "fill")
            let glowMove = CABasicAnimation(keyPath: "path")
            glowMove.fromValue = glow.presentation()?.path ?? glow.path
            glowMove.duration = 0.6
            glowMove.timingFunction = ease
            glow.add(glowMove, forKey: "fill")
        }
        line.path = linePath
        glow.path = glowPath
        CATransaction.commit()
    }

    /// A capsule `width` across, running `fraction` of the long side from the
    /// bottom (vertical) or the leading end (horizontal), centred on the short side.
    private func capsulePath(fraction: CGFloat, width: CGFloat, in bounds: CGRect) -> CGPath {
        let rect: CGRect
        switch axis {
        case .vertical:
            let length = max(width, bounds.height * fraction)
            rect = CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: length)
        case .horizontal:
            let length = max(width, bounds.width * fraction)
            rect = CGRect(x: bounds.minX, y: bounds.midY - width / 2, width: length, height: width)
        }
        return CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
    }

    private func applyColors() {
        let cg = accent.cgColor
        track.fillColor = accent.withAlphaComponent(0.2).cgColor
        glow.fillColor = cg
        glow.shadowColor = cg
        line.fillColor = cg
    }

    // MARK: Motion

    private var shouldBreathe: Bool {
        guard !reduceMotion, !screensAsleep else { return false }
        let process = ProcessInfo.processInfo
        guard !process.isLowPowerModeEnabled, process.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return false }
        return window?.occlusionState.contains(.visible) ?? false
    }

    private func refreshMotion() {
        if shouldBreathe {
            guard line.animation(forKey: Self.animationKey) == nil else { return }
            breathe()
        } else {
            holdStill()
        }
    }

    /// Glow 0 → 0.3, line 0.55 → 0.85, eased, back and forth, forever — the
    /// same curve as before, now played by the render server.
    private func breathe() {
        func animation(from: Double, to: Double) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = Self.breath
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return animation
        }
        glow.add(animation(from: 0, to: 0.3), forKey: Self.animationKey)
        line.add(animation(from: 0.55, to: 0.85), forKey: Self.animationKey)
    }

    private func holdStill() {
        glow.removeAnimation(forKey: Self.animationKey)
        line.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.opacity = Float(0.3 * Self.heldIntensity)
        line.opacity = Float(0.55 + 0.3 * Self.heldIntensity)
        CATransaction.commit()
    }
}

/// Holds the view's notification registrations and removes them when the
/// view goes away — a main-actor view's own deinit can't touch its state.
private final class ObserverTokens: @unchecked Sendable {
    private var registrations: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var occlusion: (center: NotificationCenter, token: NSObjectProtocol)?

    func add(_ center: NotificationCenter, _ token: NSObjectProtocol) {
        registrations.append((center, token))
    }

    func setOcclusion(_ center: NotificationCenter, _ token: NSObjectProtocol) {
        removeOcclusion()
        occlusion = (center, token)
    }

    func removeOcclusion() {
        if let occlusion { occlusion.center.removeObserver(occlusion.token) }
        occlusion = nil
    }

    deinit {
        for registration in registrations { registration.center.removeObserver(registration.token) }
        removeOcclusion()
    }
}
