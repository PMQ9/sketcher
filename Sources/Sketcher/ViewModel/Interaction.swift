import CoreGraphics
import Foundation

/// The editing state machine — the single source of truth for what a pointer
/// event means right now. Pointer and keyboard handlers are its transitions.
///
/// `resizing` and `rotating` carry the ORIGINAL objects so every frame
/// recomputes from them rather than accumulating float drift over a long drag.
enum Interaction: Equatable {
    case idle

    /// A new object is being dragged out. `draft` is not yet in the scene.
    case drawing(draft: DrawObject, anchor: CGPoint)

    /// Multi-click states that survive between mouse-ups. Establishing the
    /// pattern once means polyline, polygonal lasso, and curve all reuse it.
    case polyDrafting(kind: PolyKind, points: [CGPoint], preview: CGPoint)

    case draggingObjects(ids: Set<UUID>, last: CGPoint, didDuplicate: Bool)
    /// `fixed` is the world-space anchor the resize pivots on (informational for
    /// a single object, which recomputes its own anchor). `originals` are the
    /// pre-gesture objects, so every frame recomputes from them with no drift.
    case resizing(handle: Handle, originals: [UUID: DrawObject], fixed: CGPoint)
    /// `startAngle` is the pointer's angle about `center` at grab time, so the
    /// applied delta is measured from the grab, not from the shape's own axis.
    case rotating(originals: [UUID: DrawObject], center: CGPoint, startAngle: CGFloat)

    case editingText(id: UUID)

    /// Rubber-band selection of OBJECTS.
    case marquee(anchor: CGPoint, current: CGPoint)

    /// Dragging out a PIXEL region — rectangular/elliptical marquee, or the
    /// wand's tolerance drag. `mode` is the combine mode from the held modifiers.
    case selectingRegion(tool: Tool, anchor: CGPoint, current: CGPoint, mode: CombineMode)
    /// Freehand lasso: accumulating a pixel-region outline.
    case selectingLasso(points: [CGPoint], mode: CombineMode)
    /// Dragging lifted floating pixels. The float lives on the view model's
    /// `selection`; this state only spans the active drag.
    case movingFloating(last: CGPoint)

    case panning(lastViewPoint: CGPoint)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// True while a drag is actively modifying the document. History-mutating
    /// actions are refused in these states, because the single pre-gesture
    /// snapshot slot is occupied and writing to it would corrupt history.
    ///
    /// `editingText` counts: a text edit is bracketed by one `begin`/`end` pair
    /// over the whole session, so a stray `record` from a menu command mid-edit
    /// would push into an open bracket. The dedicated text setters mutate the
    /// scene directly instead, folding into the single "Text" entry at commit.
    var isMutatingGesture: Bool {
        switch self {
        case .drawing, .draggingObjects, .resizing, .rotating, .editingText: return true
        case .idle, .polyDrafting, .marquee, .panning,
             .selectingRegion, .selectingLasso, .movingFloating: return false
        }
    }

    /// True while a pixel region is being dragged out (not committed yet), so
    /// the overlay can show the in-progress marquee/lasso.
    var isSelectingRegion: Bool {
        switch self {
        case .selectingRegion, .selectingLasso: return true
        default: return false
        }
    }

    /// The text object being edited, or nil.
    var editingTextID: UUID? {
        if case .editingText(let id) = self { return id }
        return nil
    }

    /// The object currently being drawn, which the renderer must exclude from
    /// the committed pass so it is not drawn twice.
    var draftObject: DrawObject? {
        if case .drawing(let draft, _) = self { return draft }
        return nil
    }

    /// Objects being dragged live — passed to the renderer's `excluding:` so
    /// the committed cache is not rebuilt every frame.
    var liveObjectIDs: Set<UUID> {
        switch self {
        case .draggingObjects(let ids, _, _): return ids
        case .resizing(_, let originals, _), .rotating(let originals, _, _):
            return Set(originals.keys)
        case .editingText(let id): return [id]
        default: return []
        }
    }
}

enum PolyKind: Equatable, Sendable {
    case polyline
    case curve
    case polygonalLasso
}
