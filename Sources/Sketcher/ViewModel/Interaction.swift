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
    case resizing(handle: Handle, originals: [UUID: DrawObject], anchor: CGPoint)
    case rotating(originals: [UUID: DrawObject], center: CGPoint)

    case editingText(id: UUID)

    /// Rubber-band selection of OBJECTS.
    case marquee(anchor: CGPoint, current: CGPoint)

    case panning(lastViewPoint: CGPoint)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// True while a drag is actively modifying the document. History-mutating
    /// actions are refused in these states, because the single pre-gesture
    /// snapshot slot is occupied and writing to it would corrupt history.
    var isMutatingGesture: Bool {
        switch self {
        case .drawing, .draggingObjects, .resizing, .rotating: return true
        case .idle, .polyDrafting, .editingText, .marquee, .panning: return false
        }
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
        case .resizing(_, let originals, _), .rotating(let originals, _):
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
