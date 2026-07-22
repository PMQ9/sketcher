import CoreGraphics
import Foundation

/// Pure path construction, shared by rendering and hit testing. Keeping these
/// in one place is what makes "the shape you see is the shape you can click"
/// structural rather than aspirational.
enum ObjectPaths {
    static func roundedRectPath(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let r = rect.standardized
        guard cornerRadius > 0 else { return CGPath(rect: r, transform: nil) }
        return CGPath(roundedRect: r,
                      cornerWidth: min(cornerRadius, r.width / 2),
                      cornerHeight: min(cornerRadius, r.height / 2),
                      transform: nil)
    }

    /// Regular N-gon, or a star when `starInnerRatio` is set. Vertex 0 points
    /// up (-y), so a triangle looks like a triangle rather than resting on a
    /// vertex.
    static func polygonPath(in rect: CGRect, sides: Int,
                            starInnerRatio: CGFloat?) -> CGPath {
        let r = rect.standardized
        let path = CGMutablePath()
        let n = max(3, sides)
        let cx = r.midX, cy = r.midY
        let rx = r.width / 2, ry = r.height / 2
        guard rx > 0, ry > 0 else { return path }

        let step = CGFloat.pi * 2 / CGFloat(n)
        let start = -CGFloat.pi / 2   // point up

        if let ratio = starInnerRatio {
            let inner = max(0.05, min(ratio, 0.95))
            for i in 0..<(n * 2) {
                let angle = start + step * CGFloat(i) / 2
                let scale = i.isMultiple(of: 2) ? 1 : inner
                let p = CGPoint(x: cx + cos(angle) * rx * scale,
                                y: cy + sin(angle) * ry * scale)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
        } else {
            for i in 0..<n {
                let angle = start + step * CGFloat(i)
                let p = CGPoint(x: cx + cos(angle) * rx, y: cy + sin(angle) * ry)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
        }
        path.closeSubpath()
        return path
    }

    static func quadPath(from start: CGPoint, control: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    static func polylinePath(_ points: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.closeSubpath() }
        return path
    }

    /// The path a `DrawObject` draws, in its LOCAL (unrotated) frame.
    /// Returns nil for kinds that do not reduce to a single stroked/filled path
    /// (text, image, filter, stroke, unknown).
    static func path(for object: DrawObject) -> CGPath? {
        switch object.kind {
        case .rectangle(let rect, let radius):
            return roundedRectPath(rect, cornerRadius: radius)
        case .ellipse(let rect):
            return CGPath(ellipseIn: rect.standardized, transform: nil)
        case .polygon(let rect, let sides, let ratio):
            return polygonPath(in: rect, sides: sides, starInnerRatio: ratio)
        case .line(let s, let e, let c):
            if let c { return quadPath(from: s, control: c, to: e) }
            return polylinePath([s, e], closed: false)
        case .polyline(let points, let closed):
            return polylinePath(points, closed: closed)
        case .arrow, .stroke, .text, .image, .filter, .unknown:
            return nil
        }
    }
}

/// Arrow head geometry: the shaft is pulled back so the filled head owns the
/// tip, and head length is clamped so short arrows degrade gracefully instead
/// of becoming all head.
struct ArrowGeometry {
    let shaftStart: CGPoint
    let shaftEnd: CGPoint
    let headPath: CGPath?

    init(start: CGPoint, end: CGPoint, strokeWidthPx: CGFloat,
         head: ArrowHead, headScale: CGFloat = 1) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length

        guard head != .none else {
            shaftStart = start
            shaftEnd = end
            headPath = nil
            return
        }

        let headLength = min(max(strokeWidthPx * 4.5, 18) * max(headScale, 0.1),
                             length * 0.9)
        let halfWidth = headLength * 0.45
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let px = -uy, py = ux   // unit perpendicular

        shaftStart = start
        // Dot and bar heads sit ON the endpoint, so the shaft runs full length.
        shaftEnd = (head == .dot || head == .bar) ? end : base

        let path = CGMutablePath()
        switch head {
        case .none:
            headPath = nil
            return
        case .arrow, .triangle:
            path.move(to: end)
            path.addLine(to: CGPoint(x: base.x + px * halfWidth, y: base.y + py * halfWidth))
            if head == .arrow {
                // Concave notch — the classic barbed arrowhead.
                let notch = CGPoint(x: end.x - ux * headLength * 0.7,
                                    y: end.y - uy * headLength * 0.7)
                path.addLine(to: notch)
            }
            path.addLine(to: CGPoint(x: base.x - px * halfWidth, y: base.y - py * halfWidth))
            path.closeSubpath()
        case .diamond:
            let tail = CGPoint(x: end.x - ux * headLength * 2, y: end.y - uy * headLength * 2)
            path.move(to: end)
            path.addLine(to: CGPoint(x: base.x + px * halfWidth, y: base.y + py * halfWidth))
            path.addLine(to: tail)
            path.addLine(to: CGPoint(x: base.x - px * halfWidth, y: base.y - py * halfWidth))
            path.closeSubpath()
        case .dot:
            let r = max(strokeWidthPx * 1.6, 5) * headScale
            path.addEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))
        case .bar:
            let h = max(strokeWidthPx * 2.2, 8) * headScale
            let t = max(strokeWidthPx * 0.6, 1.5)
            path.move(to: CGPoint(x: end.x + px * h - ux * t, y: end.y + py * h - uy * t))
            path.addLine(to: CGPoint(x: end.x + px * h + ux * t, y: end.y + py * h + uy * t))
            path.addLine(to: CGPoint(x: end.x - px * h + ux * t, y: end.y - py * h + uy * t))
            path.addLine(to: CGPoint(x: end.x - px * h - ux * t, y: end.y - py * h - uy * t))
            path.closeSubpath()
        }
        headPath = path
    }
}
