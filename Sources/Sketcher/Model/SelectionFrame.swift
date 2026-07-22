import CoreGraphics
import Foundation

/// The interactive frame around the current selection — the resize/rotate
/// handles and the box they hang off.
///
/// CHROME ONLY: derived from the selection on demand, never stored in `Scene`,
/// never snapshotted. All positions are in canvas pixels; the view converts
/// them for drawing and hit-testing.
///
/// Three shapes, chosen by what is selected:
/// - `.box`: a single rotatable shape — its (possibly rotated) local box with 8
///   resize handles and a rotate handle floating above the top edge.
/// - `.endpoints`: a single line or arrow — one handle at each end, no box.
/// - `.group`: several objects, or a single freehand/other object — the
///   axis-aligned union box with 8 handles that scale the whole set together.
///   No rotate handle (group rotation is deferred to a later milestone).
struct SelectionFrame: Equatable {
    enum Style: Equatable { case box, endpoints, group }

    var style: Style
    /// The box the handles sit on. LOCAL (unrotated) for `.box`; world-space
    /// axis-aligned union for `.group`. `.null` for `.endpoints`.
    var box: CGRect
    /// Nonzero only for `.box`.
    var rotation: CGFloat
    /// Rotation pivot, world space.
    var center: CGPoint
    /// Every handle present, at its world-space (canvas-pixel) position.
    var handles: [Handle: CGPoint]

    // MARK: - Construction

    /// Build the frame for `objects`. `rotateOffset` is the canvas-space distance
    /// the rotate handle floats above the top edge — the caller derives it from
    /// the view transform so the handle stays a constant size on screen.
    static func make(for objects: [DrawObject], rotateOffset: CGFloat) -> SelectionFrame? {
        let visible = objects.filter { !$0.isHidden }
        if visible.count == 1, let object = visible.first {
            return single(object, rotateOffset: rotateOffset)
        }
        return group(visible)
    }

    private static func single(_ object: DrawObject,
                               rotateOffset: CGFloat) -> SelectionFrame? {
        switch object.kind {
        case .line(let s, let e, _):
            return SelectionFrame(style: .endpoints, box: .null, rotation: 0,
                                  center: object.bounds.center,
                                  handles: [.start: s, .end: e])
        case .arrow(let payload):
            return SelectionFrame(style: .endpoints, box: .null, rotation: 0,
                                  center: object.bounds.center,
                                  handles: [.start: payload.start, .end: payload.end])
        case .rectangle, .ellipse, .polygon, .text, .image, .filter:
            let b = object.localBox
            guard !b.isNull, b.width > 0 || b.height > 0 else { return nil }
            var handles = boxHandles(b)
            // Rotate handle floats above the top edge, computed on the UNROTATED
            // box, then everything is rotated rigidly around the center.
            handles[.rotate] = CGPoint(x: b.midX, y: b.minY - rotateOffset)
            let c = object.rotationCenter
            let r = object.rotation
            if r != 0 { handles = handles.mapValues { $0.rotated(around: c, by: r) } }
            return SelectionFrame(style: .box, box: b, rotation: r, center: c,
                                  handles: handles)
        case .stroke, .polyline, .unknown:
            // Move-and-scale, but not rotate: a group-style box with no rotate handle.
            return group([object])
        }
    }

    private static func group(_ objects: [DrawObject]) -> SelectionFrame? {
        let box = objects.reduce(CGRect.null) { $0.unionIgnoringNull($1.bounds) }
        guard !box.isNull, box.width > 0 || box.height > 0 else { return nil }
        return SelectionFrame(style: .group, box: box, rotation: 0,
                              center: box.center, handles: boxHandles(box))
    }

    private static func boxHandles(_ b: CGRect) -> [Handle: CGPoint] {
        [.topLeft: CGPoint(x: b.minX, y: b.minY),
         .topRight: CGPoint(x: b.maxX, y: b.minY),
         .bottomLeft: CGPoint(x: b.minX, y: b.maxY),
         .bottomRight: CGPoint(x: b.maxX, y: b.maxY),
         .top: CGPoint(x: b.midX, y: b.minY),
         .bottom: CGPoint(x: b.midX, y: b.maxY),
         .left: CGPoint(x: b.minX, y: b.midY),
         .right: CGPoint(x: b.maxX, y: b.midY)]
    }

    // MARK: - Hit testing

    /// The handle under `p` within `tolerance` (canvas pixels), or nil.
    ///
    /// The rotate handle wins first (it floats outside the box). Corners and
    /// endpoints beat edges, because at small sizes they overlap and grabbing a
    /// two-axis handle is the more common intent.
    func handleHit(at p: CGPoint, tolerance: CGFloat) -> Handle? {
        if let rotate = handles[.rotate], p.distance(to: rotate) <= tolerance {
            return .rotate
        }
        func nearest(_ candidates: [Handle]) -> Handle? {
            var best: Handle?
            var bestDist = tolerance
            for h in candidates {
                guard let pt = handles[h] else { continue }
                let d = p.distance(to: pt)
                if d <= bestDist { bestDist = d; best = h }
            }
            return best
        }
        if let corner = nearest([.topLeft, .topRight, .bottomLeft, .bottomRight,
                                 .start, .end]) {
            return corner
        }
        return nearest([.top, .bottom, .left, .right])
    }
}
