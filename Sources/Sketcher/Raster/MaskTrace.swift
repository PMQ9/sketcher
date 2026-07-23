import CoreGraphics
import Foundation

/// Trace a gray selection mask into closed polyline contours, so a mask-backed
/// (magic-wand) selection can draw marching ants.
///
/// There is NO system API to convert a bitmap mask to a `CGPath` (T3), so this
/// is hand-written: collect the unit boundary edges between selected and
/// unselected pixels, wound consistently (clockwise around each selected pixel,
/// so a blob's outer contour is CW and a hole is CCW), stitch them into closed
/// loops, and simplify each with Douglas–Peucker. The result is a Manhattan
/// outline collapsed to clean segments — exactly what pixel-accurate ants are.
///
/// `nonisolated`: it reads an immutable mask off the render path.
enum MaskTrace {
    static func contours(of mask: CGImage, canvas: CanvasSpec,
                         simplify epsilon: CGFloat = 1.0) -> [[CGPoint]] {
        let w = canvas.pixelSize.width, h = canvas.pixelSize.height
        guard w > 0, h > 0, let buf = MaskOps.readGray(mask, width: w, height: h) else { return [] }

        @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < w && y >= 0 && y < h && buf[y * w + x] > 127
        }

        // Grid vertices are (0…w, 0…h); encode as one Int for hashing.
        let vw = w + 1
        @inline(__always) func code(_ x: Int, _ y: Int) -> Int { y * vw + x }
        @inline(__always) func decode(_ c: Int) -> CGPoint {
            CGPoint(x: CGFloat(c % vw), y: CGFloat(c / vw))
        }

        // Directed boundary edges keyed by start vertex. A pinch vertex can have
        // more than one outgoing edge, so the value is a list consumed on walk.
        var edges: [Int: [Int]] = [:]
        @inline(__always) func add(_ sx: Int, _ sy: Int, _ ex: Int, _ ey: Int) {
            edges[code(sx, sy), default: []].append(code(ex, ey))
        }
        for y in 0..<h {
            for x in 0..<w where inside(x, y) {
                if !inside(x, y - 1) { add(x, y, x + 1, y) }         // top    TL→TR
                if !inside(x + 1, y) { add(x + 1, y, x + 1, y + 1) } // right  TR→BR
                if !inside(x, y + 1) { add(x + 1, y + 1, x, y + 1) } // bottom BR→BL
                if !inside(x - 1, y) { add(x, y + 1, x, y) }         // left   BL→TL
            }
        }
        guard !edges.isEmpty else { return [] }

        @inline(__always) func takeEdge(from start: Int) -> Int? {
            guard var ends = edges[start], !ends.isEmpty else { return nil }
            let end = ends.removeLast()
            if ends.isEmpty { edges.removeValue(forKey: start) } else { edges[start] = ends }
            return end
        }

        var contours: [[CGPoint]] = []
        for start in edges.keys.sorted() {
            while edges[start]?.isEmpty == false {
                var loop: [Int] = [start]
                var current = start
                while let next = takeEdge(from: current) {
                    loop.append(next)
                    current = next
                    if next == start { break }
                }
                var points = loop.map(decode)
                if points.count > 1, points.first == points.last { points.removeLast() }
                let simplified = douglasPeuckerClosed(points, epsilon: epsilon)
                if simplified.count >= 3 { contours.append(simplified) }
                else if points.count >= 3 { contours.append(points) }
            }
        }
        return contours
    }

    // MARK: - Douglas–Peucker

    /// Closed-loop DP: split at the vertex farthest from vertex 0 and simplify
    /// the two open halves. DP is only defined for open chains, so a naive pass
    /// on a closed loop would collapse it.
    static func douglasPeuckerClosed(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 3 else { return points }
        var farIndex = 1
        var farDist: CGFloat = -1
        for i in 1..<points.count {
            let d = points[i].distance(to: points[0])
            if d > farDist { farDist = d; farIndex = i }
        }
        let first = Array(points[0...farIndex])
        let second = Array(points[farIndex...]) + [points[0]]
        let a = douglasPeucker(first, epsilon: epsilon)
        let b = douglasPeucker(second, epsilon: epsilon)
        // Drop the shared endpoints so the concatenation isn't doubled.
        return Array(a.dropLast()) + Array(b.dropLast())
    }

    static func douglasPeucker(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points.first!, last = points.last!
        var maxDist: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = points[i].distanceToSegment(first, last)
            if d > maxDist { maxDist = d; index = i }
        }
        if maxDist > epsilon {
            let left = douglasPeucker(Array(points[0...index]), epsilon: epsilon)
            let right = douglasPeucker(Array(points[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [first, last]
    }
}
