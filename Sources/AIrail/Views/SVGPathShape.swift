import SwiftUI

/// Renders SVG path data (24×24 viewBox) as a SwiftUI Shape, scaled to fit
/// and centered in its rect. Parsed paths are cached; parsing happens once.
struct SVGPathShape: Shape {
    let pathData: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let base = SVGPathCache.shared.path(for: pathData)
        let scale = min(rect.width, rect.height) / viewBox
        let transform = CGAffineTransform(
            translationX: rect.midX - viewBox * scale / 2,
            y: rect.midY - viewBox * scale / 2
        ).scaledBy(x: scale, y: scale)
        return base.applying(transform)
    }
}

final class SVGPathCache: @unchecked Sendable {
    static let shared = SVGPathCache()
    private let lock = NSLock()
    private var store: [String: Path] = [:]

    func path(for data: String) -> Path {
        lock.lock()
        defer { lock.unlock() }
        if let cached = store[data] { return cached }
        let parsed = SVGPathParser.parse(data)
        store[data] = parsed
        return parsed
    }
}

/// Minimal SVG path-data parser: M/L/H/V/C/S/Q/T/A/Z, absolute and relative,
/// with implicit command repetition and compressed arc flags.
enum SVGPathParser {

    static func parse(_ d: String) -> Path {
        var path = Path()
        var reader = Reader(Array(d))
        var cmd: Character = " "
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        while reader.hasMore() {
            if let letter = reader.takeCommandLetter() {
                cmd = letter
            } else if cmd == "M" {
                cmd = "L" // implicit lineto after moveto
            } else if cmd == "m" {
                cmd = "l"
            } else if cmd == "Z" || cmd == "z" || cmd == " " {
                return path // stray numbers; bail rather than loop
            }

            var newCubicControl: CGPoint?
            var newQuadControl: CGPoint?

            switch cmd {
            case "M", "m":
                guard let p = reader.point(relativeTo: cmd == "m" ? current : nil) else { return path }
                path.move(to: p)
                current = p
                subpathStart = p
            case "L", "l":
                guard let p = reader.point(relativeTo: cmd == "l" ? current : nil) else { return path }
                path.addLine(to: p)
                current = p
            case "H", "h":
                guard let x = reader.number() else { return path }
                let p = CGPoint(x: cmd == "h" ? current.x + x : x, y: current.y)
                path.addLine(to: p)
                current = p
            case "V", "v":
                guard let y = reader.number() else { return path }
                let p = CGPoint(x: current.x, y: cmd == "v" ? current.y + y : y)
                path.addLine(to: p)
                current = p
            case "C", "c":
                let origin = cmd == "c" ? current : nil
                guard let c1 = reader.point(relativeTo: origin),
                      let c2 = reader.point(relativeTo: origin),
                      let p = reader.point(relativeTo: origin) else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                newCubicControl = c2
            case "S", "s":
                let origin = cmd == "s" ? current : nil
                let c1 = lastCubicControl.map { reflect($0, about: current) } ?? current
                guard let c2 = reader.point(relativeTo: origin),
                      let p = reader.point(relativeTo: origin) else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                newCubicControl = c2
            case "Q", "q":
                let origin = cmd == "q" ? current : nil
                guard let c = reader.point(relativeTo: origin),
                      let p = reader.point(relativeTo: origin) else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p
                newQuadControl = c
            case "T", "t":
                let origin = cmd == "t" ? current : nil
                let c = lastQuadControl.map { reflect($0, about: current) } ?? current
                guard let p = reader.point(relativeTo: origin) else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p
                newQuadControl = c
            case "A", "a":
                guard let rx = reader.number(),
                      let ry = reader.number(),
                      let rotation = reader.number(),
                      let largeArc = reader.flag(),
                      let sweep = reader.flag(),
                      let p = reader.point(relativeTo: cmd == "a" ? current : nil) else { return path }
                appendArc(
                    to: &path, from: current,
                    rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc, sweep: sweep, to: p
                )
                current = p
            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }

            lastCubicControl = newCubicControl
            lastQuadControl = newQuadControl
        }
        return path
    }

    private static func reflect(_ point: CGPoint, about center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// Elliptical arc → cubic Bézier segments (W3C endpoint parameterization).
    private static func appendArc(
        to path: inout Path, from start: CGPoint,
        rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool, to end: CGPoint
    ) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        guard rx > .ulpOfOne, ry > .ulpOfOne, start != end else {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(max(dot / length, -1), 1))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle(
            (x1p - cxp) / rx, (y1p - cyp) / ry,
            (-x1p - cxp) / rx, (-y1p - cyp) / ry
        )
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let segmentDelta = delta / CGFloat(segments)
        let alpha = 4 / 3 * tan(segmentDelta / 4)

        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(
                x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi
            )
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(
                x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi
            )
        }

        var t1 = theta1
        for _ in 0..<segments {
            let t2 = t1 + segmentDelta
            let p1 = point(t1)
            let p2 = point(t2)
            let d1 = derivative(t1)
            let d2 = derivative(t2)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + alpha * d1.x, y: p1.y + alpha * d1.y),
                control2: CGPoint(x: p2.x - alpha * d2.x, y: p2.y - alpha * d2.y)
            )
            t1 = t2
        }
    }

    private struct Reader {
        private let chars: [Character]
        private var index = 0

        init(_ chars: [Character]) {
            self.chars = chars
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == "," || chars[index].isWhitespace {
                index += 1
            }
        }

        mutating func hasMore() -> Bool {
            skipSeparators()
            return index < chars.count
        }

        mutating func takeCommandLetter() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isLetter else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            guard index < chars.count else { return nil }
            if chars[index] == "+" || chars[index] == "-" {
                text.append(chars[index])
                index += 1
            }
            var seenDot = false
            var seenExponent = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    text.append(c)
                    index += 1
                } else if c == ".", !seenDot, !seenExponent {
                    seenDot = true
                    text.append(c)
                    index += 1
                } else if c == "e" || c == "E", !seenExponent, !text.isEmpty {
                    seenExponent = true
                    text.append(c)
                    index += 1
                    if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                        text.append(chars[index])
                        index += 1
                    }
                } else {
                    break
                }
            }
            return Double(text).map { CGFloat($0) }
        }

        /// Arc flags are a single 0/1 character and may be crammed together.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
            defer { index += 1 }
            return chars[index] == "1"
        }

        mutating func point(relativeTo origin: CGPoint?) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            if let origin {
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            return CGPoint(x: x, y: y)
        }
    }
}
