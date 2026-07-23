import CoreGraphics
import Foundation

/// Freehand stroke rendering.
///
/// The geometry itself lives in `Freehand`/`BrushEngine`, which turn samples
/// into a FILLED variable-width outline — `CGContext` has no variable-width
/// stroke, so pressure requires a filled polygon, not a stroked centerline.
/// This type owns only the capture-time sample gate and the fill op.
enum StrokeGeometry {
    /// Minimum distance between retained samples. Below this, pointer jitter
    /// adds points that cost time and add nothing to the outline.
    static let minSampleDistance: CGFloat = 2

    /// True when `point` is far enough from the last sample to be worth keeping.
    static func shouldAppend(_ point: CGPoint, to samples: [StrokeSample]) -> Bool {
        guard let last = samples.last else { return true }
        return last.point.distance(to: point) >= minSampleDistance
    }

    /// Fill a closed outline polygon as ONE fill op.
    ///
    /// One fill op matters under the highlighter's multiply blend: the outline
    /// is a single self-unioning polygon, so filling it once (non-zero winding)
    /// darkens every covered pixel exactly once — filling per-segment would
    /// double-darken every overlap, which is what makes a naive highlighter look
    /// wrong.
    static func fill(_ outline: [CGPoint], color: CGColor, blendMode: CGBlendMode,
                     antialias: Bool, in ctx: CGContext) {
        guard outline.count >= 3 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setShouldAntialias(antialias)
        ctx.setBlendMode(blendMode)
        ctx.setFillColor(color)

        let path = CGMutablePath()
        path.addLines(between: outline)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()   // non-zero winding: self-overlap fills once
    }
}
