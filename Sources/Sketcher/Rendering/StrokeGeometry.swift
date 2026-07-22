import CoreGraphics
import Foundation

/// Freehand stroke geometry.
///
/// M1 ships the cheap, good-looking path: quadratic curves through segment
/// midpoints, stroked at a constant width. M6 replaces `outline(for:)` with a
/// perfect-freehand port that emits a filled variable-width polygon — note that
/// `CGContext` has no variable-width stroke, so pressure REQUIRES a filled
/// outline, not a stroked path.
enum StrokeGeometry {
    /// Minimum distance between retained samples. Below this, pointer jitter
    /// adds points that cost time and make the curve wobble.
    static let minSampleDistance: CGFloat = 2

    /// True when `point` is far enough from the last sample to be worth keeping.
    static func shouldAppend(_ point: CGPoint, to samples: [StrokeSample]) -> Bool {
        guard let last = samples.last else { return true }
        return last.point.distance(to: point) >= minSampleDistance
    }

    /// Quadratic smoothing through segment midpoints — cheap and looks
    /// hand-drawn. Each control point is the raw sample, so the curve passes
    /// through the midpoints rather than the samples themselves.
    static func smoothedPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 3 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                              y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Stroke a polyline as ONE path with ONE stroke op.
    ///
    /// The single stroke op matters: stroking segment-by-segment double-darkens
    /// every joint under a multiply blend, which is exactly what makes a naive
    /// highlighter look wrong.
    static func stroke(_ points: [CGPoint], width: CGFloat, color: CGColor,
                       blendMode: CGBlendMode, dash: DashStyle,
                       antialias: Bool, in ctx: CGContext) {
        guard let first = points.first, width > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setShouldAntialias(antialias)
        ctx.setBlendMode(blendMode)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)

        if points.count == 1 {
            // A click without a drag: round caps do NOT render a zero-length
            // line, so a tap would otherwise draw nothing at all.
            ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2,
                                       width: width, height: width))
            return
        }

        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if let lengths = dash.lengths(strokeWidth: width) {
            ctx.setLineDash(phase: 0, lengths: lengths)
        }
        ctx.addPath(smoothedPath(points))
        ctx.strokePath()
    }
}
