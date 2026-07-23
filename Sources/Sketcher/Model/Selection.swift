import CoreGraphics
import Foundation

/// What is currently selected.
///
/// INVARIANT: selection is VIEW-MODEL state. It never enters `Scene`, is never
/// snapshotted, and selection changes are not undoable — matching every
/// shipping editor.
///
/// Multi-select exists from day one deliberately: retrofitting `Set<UUID>`
/// after a full tool palette exists means paying for every tool twice.
struct Selection: Equatable {
    /// Object domain — the `V` tool.
    var objectIDs: Set<UUID> = []
    /// Set by double-clicking into a group, cleared by Esc.
    var editingGroupPath: [UUID] = []

    /// Pixel domain — the `M`/`Q`/`W` tools, on the active raster layer.
    /// Populated from M7.
    var region: SelectionShape? = nil
    var featherPx: CGFloat = 0
    /// Pixels lifted off a layer and living under a live transform (M7).
    var floating: FloatingPixels? = nil

    var isEmpty: Bool {
        objectIDs.isEmpty && region == nil && floating == nil
    }

    var hasObjects: Bool { !objectIDs.isEmpty }

    /// A pixel region is active (marquee/lasso/wand result), whether or not
    /// pixels have been lifted off it yet.
    var hasRegion: Bool { region != nil }

    /// Surfaces this selection owns. They live in `SurfaceStore` but are
    /// referenced by neither `Scene` nor `History`, so the prune keep-set must
    /// include them or a wand mask / floating buffer is collected out from under
    /// a live selection.
    var referencedSurfaceIDs: Set<SurfaceID> {
        var ids = Set<SurfaceID>()
        if case .mask(let id, _)? = region { ids.insert(id) }
        if let floating { ids.insert(floating.surface) }
        return ids
    }

    mutating func clear() {
        objectIDs.removeAll()
        editingGroupPath.removeAll()
        region = nil
        floating = nil
    }

    mutating func select(_ id: UUID) {
        objectIDs = [id]
    }

    mutating func toggle(_ id: UUID) {
        if objectIDs.contains(id) { objectIDs.remove(id) } else { objectIDs.insert(id) }
    }
}

/// A pixel-domain selection region.
///
/// Value-typed on purpose: `CGPath` is neither Equatable, Hashable, nor
/// Sendable in the SDK, so storing one would break synthesized Equatable and
/// therefore `Scene.==`. The `CGPath` is derived lazily for clipping and
/// marching ants, and never stored.
enum SelectionShape: Equatable {
    case rect(CGRect)
    case ellipse(CGRect)
    case polygon(points: [CGPoint], evenOdd: Bool)
    /// The result of combining two analytic shapes through a `CGPath` boolean
    /// (union/subtract/intersect). Reuses the value-typed `PathGeometry` — the
    /// booleans flatten curves to polylines, which is exactly what it stores —
    /// so a combined selection stays exact and resolution-independent, with no
    /// marching-squares trace needed for its ants (that is only for masks).
    case compound(PathGeometry)
    /// Magic-wand output. The mask is 8-bit DeviceGray with
    /// `CGImageAlphaInfo.none` — NOT alphaOnly, which `CGContext.clip(to:mask:)`
    /// rejects outright. Polarity: 255 = selected. `bounds` is the tight
    /// nonzero box, so the ants trace and any lift crop stay small.
    case mask(SurfaceID, bounds: CGRect)

    var bounds: CGRect {
        switch self {
        case .rect(let r), .ellipse(let r): return r
        case .polygon(let points, _): return CGRect(containing: points)
        case .compound(let geometry): return geometry.bounds
        case .mask(_, let bounds): return bounds
        }
    }

    /// The fill rule the derived path must use. Self-intersecting lassos and
    /// boolean results both need this carried, or a crossing reads as a hole.
    var usesEvenOdd: Bool {
        switch self {
        case .polygon(_, let evenOdd): return evenOdd
        case .compound(let geometry): return geometry.evenOdd
        case .rect, .ellipse, .mask: return false
        }
    }

    /// True when this region clips through an alpha mask rather than a path.
    var isMask: Bool {
        if case .mask = self { return true }
        return false
    }

    /// nil for mask-backed selections, which clip through `clip(to:mask:)`
    /// instead of a path.
    func makePath() -> CGPath? {
        switch self {
        case .rect(let r):
            return CGPath(rect: r, transform: nil)
        case .ellipse(let r):
            return CGPath(ellipseIn: r, transform: nil)
        case .polygon(let points, _):
            return ObjectPaths.polylinePath(points, closed: true)
        case .compound(let geometry):
            return geometry.isEmpty ? nil : geometry.makePath()
        case .mask:
            return nil
        }
    }
}

/// How a freshly-drawn region combines with the existing one — driven by the
/// modifier keys held during the gesture (Shift union, Option subtract,
/// Shift+Option intersect), matching Photoshop / Paint.NET.
enum CombineMode: Equatable, Sendable {
    case replace, union, subtract, intersect

    init(shift: Bool, option: Bool) {
        switch (shift, option) {
        case (true, true): self = .intersect
        case (true, false): self = .union
        case (false, true): self = .subtract
        case (false, false): self = .replace
        }
    }
}

/// Paint's floating selection: pixels lifted off a layer, living under a live
/// transform, composited back down on commit.
///
/// This is the mechanism that makes move / scale / rotate / flip / cut / copy /
/// paste fall out of ONE code path instead of six. The original image is kept
/// and the transform is recomputed from `originalTransform` every frame, so a
/// long drag never degrades through resample-of-resample.
struct FloatingPixels: Equatable {
    var surface: SurfaceID
    var sourceRect: CGRect
    var transform: CGAffineTransform
    var originalTransform: CGAffineTransform
    /// nil for a paste — there is nothing to restore underneath.
    var liftedFromLayer: Layer.ID?
    var liftMode: LiftMode
}

enum LiftMode: Equatable, Sendable {
    /// Source region cleared to transparent.
    case cut
    /// Source region filled with the secondary color — classic Paint's
    /// opaque-selection behavior.
    case cutToSecondary(RGBAColor)
    /// Source untouched (Option-drag, or a paste).
    case copy
}
