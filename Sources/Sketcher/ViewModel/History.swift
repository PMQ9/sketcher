import CoreGraphics
import Foundation

/// One undoable step.
///
/// Heterogeneous on purpose: a vector edit snapshots the whole `Scene` (which
/// is genuinely kilobytes, because `Scene` holds `SurfaceID` handles rather
/// than pixels), while a raster edit stores a tile-quantized pixel diff.
enum HistoryEntry {
    case scene(Scene, name: String)
    case rasterPatch(RasterPatch, name: String)

    var name: String {
        switch self {
        case .scene(_, let name), .rasterPatch(_, let name): return name
        }
    }

    /// Approximate retained bytes, used by the eviction budget.
    var byteCount: Int {
        switch self {
        case .scene: return 4096                  // handles + geometry, not pixels
        case .rasterPatch(let patch, _): return patch.byteCount
        }
    }

    var isRaster: Bool {
        if case .rasterPatch = self { return true }
        return false
    }
}

/// A tile-quantized pixel diff for one raster layer.
///
/// CRITICAL: `before` and `after` must be MATERIALIZED into fresh bitmap
/// contexts. `CGImage.cropping(to:)` does NOT copy pixels — the SDK header
/// states the result "retains a reference to the original image" — so a naive
/// dirty-rect patch secretly pins the entire canvas, and 50 patches become
/// gigabytes. See `RasterUndoTests`.
struct RasterPatch {
    let layerID: Layer.ID
    /// Quantized to `tileSize` so a long stroke does not produce hundreds of
    /// oddly-shaped patches.
    let rect: CGRect
    let before: SurfaceID
    let after: SurfaceID
    let byteCount: Int

    static let tileSize: CGFloat = 128

    /// Expand a dirty rect out to tile boundaries and clamp to the canvas.
    static func quantize(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isEmpty else { return .null }
        let t = tileSize
        let expanded = CGRect(x: (rect.minX / t).rounded(.down) * t,
                              y: (rect.minY / t).rounded(.down) * t,
                              width: 0, height: 0)
        let maxX = (rect.maxX / t).rounded(.up) * t
        let maxY = (rect.maxY / t).rounded(.up) * t
        return CGRect(x: expanded.minX, y: expanded.minY,
                      width: maxX - expanded.minX,
                      height: maxY - expanded.minY).intersection(bounds)
    }
}

/// GIMP's dual policy: a floor of recent steps always retained, plus a byte
/// budget past which the oldest raster patches are evicted.
///
/// `.scene` entries are NEVER evicted — and that is affordable precisely
/// because `Scene` holds `SurfaceID`s rather than `CGImage`s.
struct HistoryBudget {
    var maxSurfaceBytes: Int = 512 << 20   // 512 MB
    var minEntries: Int = 25
}

/// Undo/redo stacks plus the gesture bracket.
///
/// The bracket is the load-bearing part: `begin()` captures a snapshot,
/// `end()` pushes it ONLY if the scene actually changed. That single check
/// eliminates most "empty undo entry" bugs.
struct History {
    private(set) var undoStack: [HistoryEntry] = []
    private(set) var redoStack: [HistoryEntry] = []
    var budget = HistoryBudget()

    /// Captured at gesture start; nil when no gesture is in flight.
    private(set) var preGestureScene: Scene?
    /// Depth counter so a slider drag (many value changes) coalesces into ONE
    /// undo entry rather than one per tick.
    private var interactiveDepth = 0

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isGestureInFlight: Bool { preGestureScene != nil }

    var undoActionName: String? { undoStack.last?.name }
    var redoActionName: String? { redoStack.last?.name }

    // MARK: - Gesture bracket

    mutating func begin(_ scene: Scene) {
        // A nested begin must not clobber the outer snapshot, or the outer
        // gesture loses its restore point.
        guard preGestureScene == nil else { return }
        preGestureScene = scene
    }

    /// Push the pre-gesture snapshot if — and only if — the scene changed.
    @discardableResult
    mutating func end(_ scene: Scene, name: String) -> Bool {
        guard let snapshot = preGestureScene else { return false }
        preGestureScene = nil
        guard snapshot != scene else { return false }
        push(.scene(snapshot, name: name))
        return true
    }

    /// Abandon the in-flight gesture and return the scene to restore, if any.
    mutating func abort() -> Scene? {
        defer { preGestureScene = nil }
        return preGestureScene
    }

    // MARK: - Interactive edits (sliders, steppers)

    mutating func beginInteractive(_ scene: Scene) {
        if interactiveDepth == 0 { begin(scene) }
        interactiveDepth += 1
    }

    @discardableResult
    mutating func endInteractive(_ scene: Scene, name: String) -> Bool {
        guard interactiveDepth > 0 else { return false }
        interactiveDepth -= 1
        guard interactiveDepth == 0 else { return false }
        return end(scene, name: name)
    }

    // MARK: - Direct push

    mutating func push(_ entry: HistoryEntry) {
        undoStack.append(entry)
        redoStack.removeAll()
        evictIfNeeded()
    }

    /// Record a completed change in one call, for actions with no drag phase
    /// (delete, z-order, paste).
    @discardableResult
    mutating func record(from before: Scene, to after: Scene, name: String) -> Bool {
        guard before != after else { return false }
        push(.scene(before, name: name))
        return true
    }

    // MARK: - Undo / redo

    /// Pop one step. `current` is the live scene, which becomes the redo entry.
    mutating func undo(current: Scene) -> HistoryEntry? {
        guard let entry = undoStack.popLast() else { return nil }
        switch entry {
        case .scene(_, let name):
            redoStack.append(.scene(current, name: name))
        case .rasterPatch(let patch, let name):
            redoStack.append(.rasterPatch(patch, name: name))
        }
        return entry
    }

    mutating func redo(current: Scene) -> HistoryEntry? {
        guard let entry = redoStack.popLast() else { return nil }
        switch entry {
        case .scene(_, let name):
            undoStack.append(.scene(current, name: name))
        case .rasterPatch(let patch, let name):
            undoStack.append(.rasterPatch(patch, name: name))
        }
        return entry
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        preGestureScene = nil
        interactiveDepth = 0
    }

    // MARK: - Eviction

    private mutating func evictIfNeeded() {
        var total = undoStack.reduce(0) { $0 + $1.byteCount }
        guard total > budget.maxSurfaceBytes else { return }
        var index = 0
        while index < undoStack.count,
              undoStack.count > budget.minEntries,
              total > budget.maxSurfaceBytes {
            if undoStack[index].isRaster {
                total -= undoStack[index].byteCount
                undoStack.remove(at: index)
            } else {
                index += 1
            }
        }
    }
}
