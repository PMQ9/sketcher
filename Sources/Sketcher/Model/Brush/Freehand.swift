import CoreGraphics
import Foundation

/// A Swift port of `perfect-freehand` (Steve Ruiz, MIT). Turns a pressure- and
/// velocity-annotated sample list into a FILLED variable-width outline polygon.
///
/// This is the load-bearing reason strokes are stored as samples, not paths:
/// `CGContext` has no variable-width stroke, so pressure REQUIRES a filled
/// outline rather than a stroked centerline. The outline is DERIVED here at
/// render time and never stored, so changing `size` or `thinning` re-renders
/// losslessly (invariant: the rendered outline is derived from samples).
///
/// Port note: upstream perfect-freehand also applies `streamline` (an
/// exponential low-pass) to the points here. This port relocates live jitter
/// reduction to `OneEuroFilter`, which is a strictly better stabilizer and runs
/// at capture time; `Freehand` therefore owns only the geometry — pressure,
/// tapering, and the outline. Pure and deterministic: same input, same polygon.
enum Freehand {
    struct Options {
        /// Nominal diameter in canvas pixels. Full-pressure width can exceed it
        /// (upstream semantics: `size` is nominal, pressure scales around it).
        var size: CGFloat = 16
        /// 0 = constant width; 1 = pressure fully drives width. Negative inverts.
        var thinning: CGFloat = 0.5
        /// Outline corner smoothing — larger drops more near-colinear points.
        var smoothing: CGFloat = 0.5
        /// Velocity-derived pressure so a plain mouse still tapers.
        var simulatePressure = true
        var capStart = true
        var capEnd = true
        /// Length (px) over which the ends taper to a point. 0 = no taper.
        var taperStart: CGFloat = 0
        var taperEnd: CGFloat = 0
    }

    struct InputPoint {
        var point: CGPoint
        var pressure: CGFloat = 0.5
    }

    /// Per-sample geometry derived in the first pass.
    private struct StrokePoint {
        var point: CGPoint
        var pressure: CGFloat
        /// Unit vector pointing BACK toward the previous point (upstream convention).
        var vector: CGVector
        var distance: CGFloat
        var runningLength: CGFloat
    }

    private static let rateOfPressureChange: CGFloat = 0.275
    /// The fixed 1/13 arc step upstream uses for round caps and dots.
    private static let capSteps = 13

    /// The closed outline polygon for `inputs`, or a single filled dot when the
    /// stroke is one point. Empty when there is nothing to draw.
    static func outline(_ inputs: [InputPoint], options o: Options) -> [CGPoint] {
        guard o.size > 0, !inputs.isEmpty else { return [] }
        let points = strokePoints(inputs)
        return outlinePoints(points, options: o)
    }

    // MARK: - Pass 1: per-sample geometry

    private static func strokePoints(_ inputs: [InputPoint]) -> [StrokePoint] {
        var pts = inputs
        // A single point needs a second, nudged one so it has a direction; the
        // outline pass then collapses it into a dot.
        if pts.count == 1 {
            pts.append(InputPoint(point: CGPoint(x: pts[0].point.x + 1,
                                                 y: pts[0].point.y + 1),
                                  pressure: pts[0].pressure))
        }

        var result: [StrokePoint] = [
            StrokePoint(point: pts[0].point, pressure: max(pts[0].pressure, 0),
                        vector: .zero, distance: 0, runningLength: 0)
        ]
        var runningLength: CGFloat = 0
        var prev = result[0]

        for i in 1..<pts.count {
            let point = pts[i].point
            if point.equalTo(prev.point) { continue }
            let distance = point.distance(to: prev.point)
            runningLength += distance
            let sp = StrokePoint(point: point,
                                 pressure: pts[i].pressure,
                                 vector: unit(prev.point - point),
                                 distance: distance,
                                 runningLength: runningLength)
            result.append(sp)
            prev = sp
        }
        // The first point inherits the second's direction so its cap points sane.
        if result.count > 1 { result[0].vector = result[1].vector }
        return result
    }

    // MARK: - Pass 2: outline

    private static func outlinePoints(_ points: [StrokePoint],
                                      options o: Options) -> [CGPoint] {
        let n = points.count
        guard n > 0 else { return [] }
        let totalLength = points[n - 1].runningLength

        // A dot: one distinct point. Ring of cap points around it.
        if n == 1 || totalLength == 0 {
            let center = points[0].point
            let r = max(strokeRadius(o.size, o.thinning, points[0].pressure), 0.01)
            var dot: [CGPoint] = []
            for step in 0..<capSteps {
                let t = CGFloat(step) / CGFloat(capSteps) * 2 * .pi
                dot.append(CGPoint(x: center.x + cos(t) * r, y: center.y + sin(t) * r))
            }
            return dot
        }

        let minDistanceSq = (o.size * o.smoothing) * (o.size * o.smoothing)

        var left: [CGPoint] = []
        var right: [CGPoint] = []

        // Seed pressure with a short average, simulated from velocity when asked.
        var prevPressure = points[0].pressure
        for p in points.prefix(10) {
            var pressure = p.pressure
            if o.simulatePressure {
                let sp = min(1, p.distance / o.size)
                let rp = min(1, 1 - sp)
                pressure = min(1, prevPressure + (rp - prevPressure) * (sp * rateOfPressureChange))
            }
            prevPressure = (prevPressure + pressure) / 2
        }

        var pl = points[0].point
        var pr = points[0].point

        for i in 0..<n {
            let sp = points[i]
            // Drop the last few px of samples: end jitter otherwise flares the cap.
            if i < n - 1 && totalLength - sp.runningLength < 3 { continue }

            var pressure = sp.pressure
            var radius: CGFloat
            if o.thinning != 0 {
                if o.simulatePressure {
                    let s = min(1, sp.distance / o.size)
                    let rp = min(1, 1 - s)
                    pressure = min(1, prevPressure + (rp - prevPressure) * (s * rateOfPressureChange))
                }
                radius = strokeRadius(o.size, o.thinning, pressure)
            } else {
                radius = o.size / 2
            }

            // Taper the ends toward a point.
            let ts = o.taperStart > 0 && sp.runningLength < o.taperStart
                ? taperEase(sp.runningLength / o.taperStart) : 1
            let te = o.taperEnd > 0 && (totalLength - sp.runningLength) < o.taperEnd
                ? taperEase((totalLength - sp.runningLength) / o.taperEnd) : 1
            radius = max(0.01, radius * min(ts, te))

            let nextVector = (i < n - 1 ? points[i + 1] : sp).vector
            let nextDpr = i < n - 1 ? dot(sp.vector, nextVector) : 1

            // Final point: square off along its own normal.
            if i == n - 1 {
                let offset = normal(sp.vector) * radius
                left.append(sp.point - offset)
                right.append(sp.point + offset)
                continue
            }

            // Offset along the averaged tangent, which is what keeps the two
            // sides parallel through a curve instead of pinching on the inside.
            let offset = normal(lerp(nextVector, sp.vector, nextDpr)) * radius
            let tl = sp.point - offset
            let tr = sp.point + offset
            if i <= 1 || pl.distanceSquared(to: tl) > minDistanceSq { left.append(tl); pl = tl }
            if i <= 1 || pr.distanceSquared(to: tr) > minDistanceSq { right.append(tr); pr = tr }
            prevPressure = pressure
        }

        guard let firstPoint = points.first?.point,
              let lastPoint = points.last?.point,
              !left.isEmpty, !right.isEmpty else { return [] }

        // Round caps: a half-circle arc swept from one side to the other.
        let startCap = o.capStart ? arc(from: right[0], around: firstPoint) : []
        let endCap = o.capEnd
            ? arc(from: left[left.count - 1], around: lastPoint) : []

        // left forward, end cap, right reversed, start cap — one closed loop.
        return left + endCap + right.reversed() + startCap
    }

    /// `size * ease(0.5 - thinning*(0.5 - pressure))` — upstream's radius curve,
    /// identity easing. Returns the perpendicular half-width at this sample.
    private static func strokeRadius(_ size: CGFloat, _ thinning: CGFloat,
                                     _ pressure: CGFloat) -> CGFloat {
        guard thinning != 0 else { return size / 2 }
        let p = min(max(pressure, 0), 1)
        return size * (0.5 - thinning * (0.5 - p))
    }

    /// A half-circle of `capSteps` points from `start` swept about `center`.
    private static func arc(from start: CGPoint, around center: CGPoint) -> [CGPoint] {
        var out: [CGPoint] = []
        for step in 1..<capSteps {
            let t = CGFloat(step) / CGFloat(capSteps) * .pi
            out.append(rotate(start, around: center, by: t))
        }
        return out
    }

    // Ease-out used for both tapers (upstream uses distinct curves per end; one
    // ease-out reads the same at this stroke scale and halves the surface).
    private static func taperEase(_ t: CGFloat) -> CGFloat { t * (2 - t) }

    // MARK: - Vector helpers (local so the geometry reads like the JS source)

    private static func unit(_ v: CGPoint) -> CGVector {
        let len = hypot(v.x, v.y)
        guard len > 0 else { return .zero }
        return CGVector(dx: v.x / len, dy: v.y / len)
    }
    private static func normal(_ v: CGVector) -> CGVector { CGVector(dx: v.dy, dy: -v.dx) }
    private static func dot(_ a: CGVector, _ b: CGVector) -> CGFloat { a.dx * b.dx + a.dy * b.dy }
    private static func lerp(_ a: CGVector, _ b: CGVector, _ t: CGFloat) -> CGVector {
        CGVector(dx: a.dx + (b.dx - a.dx) * t, dy: a.dy + (b.dy - a.dy) * t)
    }
    private static func rotate(_ p: CGPoint, around c: CGPoint, by angle: CGFloat) -> CGPoint {
        let s = sin(angle), co = cos(angle)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }
}

private extension CGPoint {
    // `CGPoint - CGPoint` already lives in Geometry.swift; these add the
    // point±vector forms the outline math needs.
    static func - (a: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: a.x - v.dx, y: a.y - v.dy) }
    static func + (a: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: a.x + v.dx, y: a.y + v.dy) }
    func distanceSquared(to o: CGPoint) -> CGFloat {
        let dx = x - o.x, dy = y - o.y
        return dx * dx + dy * dy
    }
}

private extension CGVector {
    static func * (v: CGVector, s: CGFloat) -> CGVector { CGVector(dx: v.dx * s, dy: v.dy * s) }
}
