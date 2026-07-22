import CoreGraphics
import Foundation

// Geometry helpers shared by hit testing, handles, and rendering.
// Everything here is in CANVAS PIXELS, top-left origin, y-down.

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    /// Rotate this point `angle` radians about `center`.
    func rotated(around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let s = sin(angle), c = cos(angle)
        let dx = x - center.x, dy = y - center.y
        return CGPoint(x: center.x + dx * c - dy * s,
                       y: center.y + dx * s + dy * c)
    }

    func distanceToSegment(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * abx + (y - a.y) * aby) / lengthSquared))
        return distance(to: CGPoint(x: a.x + t * abx, y: a.y + t * aby))
    }

    /// Bounding-box short-circuit, then per-segment distance.
    func isNear(polyline points: [CGPoint], within tolerance: CGFloat) -> Bool {
        guard !points.isEmpty else { return false }
        guard CGRect(containing: points)
            .insetBy(dx: -tolerance, dy: -tolerance).contains(self) else { return false }
        if points.count == 1 { return distance(to: points[0]) <= tolerance }
        for i in 0..<(points.count - 1)
        where distanceToSegment(points[i], points[i + 1]) <= tolerance {
            return true
        }
        return false
    }

    static func + (a: CGPoint, b: CGPoint) -> CGPoint {
        CGPoint(x: a.x + b.x, y: a.y + b.y)
    }

    static func - (a: CGPoint, b: CGPoint) -> CGPoint {
        CGPoint(x: a.x - b.x, y: a.y - b.y)
    }
}

extension CGRect {
    /// Normalized rect spanning two drag points.
    init(dragFrom a: CGPoint, to b: CGPoint) {
        self.init(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
                  width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    init(containing points: [CGPoint]) {
        guard let first = points.first else {
            self = .zero
            return
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// True if `p` lies within `band` of the rect's border (not deep inside),
    /// so an unfilled shape can be clicked through.
    func borderBandContains(_ p: CGPoint, band: CGFloat) -> Bool {
        let outer = insetBy(dx: -band, dy: -band)
        guard outer.contains(p) else { return false }
        let inner = insetBy(dx: band, dy: band)
        if inner.isNull || inner.isEmpty || inner.width <= 0 || inner.height <= 0 { return true }
        return !inner.contains(p)
    }

    /// True if `p` lies within `band` of the ellipse border inscribed in this
    /// rect, using the first-order distance approximation |f| / |∇f| for
    /// f = (dx/a)² + (dy/b)² − 1. (Scaling the ring deviation by min(a,b)
    /// balloons the hit zone along the major axis of eccentric ellipses.)
    func ellipseBorderContains(_ p: CGPoint, band: CGFloat) -> Bool {
        let a = width / 2, b = height / 2
        guard a > 0.5, b > 0.5 else {
            // Degenerate (hairline) ellipse renders as a line: hit like a rect border.
            return borderBandContains(p, band: band)
        }
        let dx = p.x - midX, dy = p.y - midY
        let f = (dx * dx) / (a * a) + (dy * dy) / (b * b) - 1
        let gradient = hypot(2 * dx / (a * a), 2 * dy / (b * b))
        guard gradient > 0 else { return band >= Swift.min(a, b) }   // exact center
        return abs(f) / gradient <= band
    }

    /// The corner diagonally opposite `handle` — the fixed anchor during resize.
    func oppositeCorner(_ handle: Handle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: maxX, y: maxY)
        case .topRight: return CGPoint(x: minX, y: maxY)
        case .bottomLeft: return CGPoint(x: maxX, y: minY)
        case .bottomRight: return CGPoint(x: minX, y: minY)
        case .top: return CGPoint(x: midX, y: maxY)
        case .bottom: return CGPoint(x: midX, y: minY)
        case .left: return CGPoint(x: maxX, y: midY)
        case .right: return CGPoint(x: minX, y: midY)
        case .start, .end, .rotate: return center
        }
    }

    func movingCorner(_ handle: Handle, to p: CGPoint) -> CGRect {
        switch handle {
        case .start, .end, .rotate:
            return self
        case .top:
            return CGRect(dragFrom: CGPoint(x: minX, y: Swift.min(p.y, maxY)),
                          to: CGPoint(x: maxX, y: maxY))
        case .bottom:
            return CGRect(dragFrom: CGPoint(x: minX, y: minY),
                          to: CGPoint(x: maxX, y: Swift.max(p.y, minY)))
        case .left:
            return CGRect(dragFrom: CGPoint(x: Swift.min(p.x, maxX), y: minY),
                          to: CGPoint(x: maxX, y: maxY))
        case .right:
            return CGRect(dragFrom: CGPoint(x: minX, y: minY),
                          to: CGPoint(x: Swift.max(p.x, minX), y: maxY))
        default:
            return CGRect(dragFrom: oppositeCorner(handle), to: p)
        }
    }

    /// Union that treats `.null` as identity, unlike `CGRect.union` on `.zero`.
    func unionIgnoringNull(_ other: CGRect) -> CGRect {
        if isNull || isEmpty { return other }
        if other.isNull || other.isEmpty { return self }
        return union(other)
    }
}

/// Resize / rotate handles. Edge handles (top/bottom/left/right) exist so a
/// shape can be stretched on one axis; arrows expose their endpoints instead.
enum Handle: Sendable, Hashable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right
    case start, end      // arrow / line endpoints
    case rotate          // floats above the shape

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }
}
