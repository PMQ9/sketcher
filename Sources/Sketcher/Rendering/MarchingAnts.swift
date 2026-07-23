import CoreGraphics
import Foundation

/// The geometry of a selection's marching ants, in canvas pixels. The overlay
/// converts to view space and strokes it twice (white, then an animated black
/// dash) — the animation and color live in the SwiftUI chrome, never here, so
/// ants can never reach an export.
///
/// Path-expressible regions (rect / ellipse / polygon / compound) decompose
/// their own path to polylines; a mask-backed (wand) region is traced by
/// marching squares (T3). A lifted floating selection outlines its transformed
/// source rectangle instead of the region it came from.
enum MarchingAnts {
    static func contours(for selection: Selection, canvas: CanvasSpec,
                         surfaces: SurfaceStore) -> [[CGPoint]] {
        if let floating = selection.floating {
            let r = floating.sourceRect
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            return [corners.map { $0.applying(floating.transform) }]
        }
        guard let region = selection.region else { return [] }
        switch region {
        case .rect, .ellipse, .polygon, .compound:
            guard let path = region.makePath() else { return [] }
            return path.selectionGeometry().subpaths.filter { $0.count >= 2 }
        case .mask(let id, _):
            guard let mask = surfaces.image(id) else { return [] }
            return MaskTrace.contours(of: mask, canvas: canvas)
        }
    }
}
