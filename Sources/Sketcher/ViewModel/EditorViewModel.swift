import CoreGraphics
import Foundation
import Observation

/// One editor's state. Owns the scene, the history, the interaction state
/// machine, and the viewport transform.
///
/// INVARIANT: `scene` holds content only. Tool, selection, viewport, and
/// interaction live here and are never snapshotted.
@MainActor
@Observable
final class EditorViewModel {
    // MARK: - Document state

    private(set) var scene: Scene {
        // Bumped on every mutation, including in-place ones — calling a
        // mutating method on a stored property triggers didSet. This is the
        // render cache's key.
        //
        // A counter rather than a `Scene ==` check on purpose: deep-comparing
        // thousands of objects on the EQUAL path (the common case) costs about
        // as much as the render it was meant to avoid. Over-invalidating is
        // safe; under-invalidating is a stale-canvas bug.
        didSet { sceneRevision &+= 1 }
    }
    /// Monotonic. Wraps harmlessly — the cache only ever compares for equality.
    private(set) var sceneRevision: UInt64 = 0

    let surfaces: SurfaceStore
    let caches = RenderCaches()
    private(set) var history = History()

    /// Called after any change that should mark the document dirty.
    /// Wired to `NSDocument.updateChangeCount` by the document.
    var onChange: ((ChangeKind) -> Void)?

    enum ChangeKind { case done, undone, redone, cleared }

    // MARK: - View-model state (never snapshotted)

    var tool: Tool = .brush {
        didSet {
            guard tool != oldValue else { return }
            // A tool switch must resolve whatever is in flight, or a half-drawn
            // draft leaks into the next gesture.
            resolveInFlightInteraction()
        }
    }

    private(set) var interaction: Interaction = .idle
    var selection = Selection()
    var transform = CanvasTransform(scale: 1, offset: .zero)
    /// Set by the canvas view so viewport commands know the viewport size.
    var viewSize: CGSize = .zero

    /// Style applied to the next created object. When something is selected,
    /// edits to these fields apply to the selection instead.
    var style: ObjectStyle
    var brush = BrushSpec()

    var primaryColor: RGBAColor {
        didSet { style.strokeColor = primaryColor }
    }
    var secondaryColor: RGBAColor = .white

    // MARK: - Init

    init(scene: Scene, surfaces: SurfaceStore = SurfaceStore()) {
        self.scene = scene
        self.surfaces = surfaces
        let ink = scene.canvas.background.defaultInk
        self.primaryColor = ink
        self.style = .default(ink: ink)
        self.brush.sizePx = scene.canvas.px(fromPoints: 3)
        self.style.strokeWidthPx = scene.canvas.px(fromPoints: 3)
    }

    // MARK: - Derived

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Objects the committed render pass must skip because they are being
    /// drawn live this frame.
    var liveObjectIDs: Set<UUID> { interaction.liveObjectIDs }

    var draftObject: DrawObject? { interaction.draftObject }

    // MARK: - Pointer

    /// - Parameters:
    ///   - p: canvas-pixel location, already converted by `CanvasTransform`.
    ///   - tolerance: hit slop in canvas pixels (constant on screen).
    func pointerDown(at p: CGPoint, tolerance: CGFloat, modifiers: EventModifiers) {
        switch tool {
        case .hand:
            return   // panning is driven by the view, which owns view-space deltas

        case .select:
            beginSelectGesture(at: p, tolerance: tolerance, modifiers: modifiers)

        case .brush, .eraser:
            beginStroke(at: p, modifiers: modifiers)

        case .rectangle, .ellipse, .polygon, .line, .arrow:
            beginShape(at: p, modifiers: modifiers)

        default:
            // Tools landing in later milestones fall through to select-like
            // behavior rather than doing something surprising.
            beginSelectGesture(at: p, tolerance: tolerance, modifiers: modifiers)
        }
    }

    func pointerDragged(to p: CGPoint, pressure: CGFloat = 1,
                        modifiers: EventModifiers = []) {
        switch interaction {
        case .drawing(var draft, let anchor):
            updateDraft(&draft, anchor: anchor, to: p, pressure: pressure,
                        modifiers: modifiers)
            interaction = .drawing(draft: draft, anchor: anchor)

        case .draggingObjects(let ids, let last, let didDuplicate):
            let delta = CGPoint(x: p.x - last.x, y: p.y - last.y)
            translateSelected(ids: ids, by: delta)
            interaction = .draggingObjects(ids: ids, last: p, didDuplicate: didDuplicate)

        case .marquee(let anchor, _):
            interaction = .marquee(anchor: anchor, current: p)
            updateMarqueeSelection(from: anchor, to: p)

        case .idle, .polyDrafting, .resizing, .rotating, .editingText, .panning:
            break
        }
    }

    func pointerUp(at p: CGPoint) {
        switch interaction {
        case .drawing(let draft, let anchor):
            interaction = .idle
            commitDraft(draft, anchor: anchor, end: p)

        case .draggingObjects:
            interaction = .idle
            history.end(scene, name: "Move")
            onChange?(.done)

        case .marquee:
            interaction = .idle

        case .idle, .polyDrafting, .resizing, .rotating, .editingText, .panning:
            interaction = .idle
        }
    }

    // MARK: - Gesture starts

    private func beginSelectGesture(at p: CGPoint, tolerance: CGFloat,
                                    modifiers: EventModifiers) {
        if let hit = topmostObject(at: p, tolerance: tolerance) {
            if modifiers.contains(.shift) {
                selection.toggle(hit.id)
            } else if !selection.objectIDs.contains(hit.id) {
                selection.select(hit.id)
            }
            guard !selection.objectIDs.isEmpty else { return }
            history.begin(scene)
            interaction = .draggingObjects(ids: selection.objectIDs, last: p,
                                           didDuplicate: false)
        } else {
            if !modifiers.contains(.shift) { selection.clear() }
            interaction = .marquee(anchor: p, current: p)
        }
    }

    private func beginStroke(at p: CGPoint, modifiers: EventModifiers) {
        var strokeStyle = style
        strokeStyle.strokeColor = primaryColor
        let payload = StrokePayload(samples: [StrokeSample(point: p)], brush: brush)
        let draft = DrawObject(kind: .stroke(payload), style: strokeStyle)
        history.begin(scene)
        interaction = .drawing(draft: draft, anchor: p)
    }

    private func beginShape(at p: CGPoint, modifiers: EventModifiers) {
        var shapeStyle = style
        shapeStyle.strokeColor = primaryColor
        let kind: ObjectKind
        switch tool {
        case .rectangle:
            kind = .rectangle(rect: CGRect(origin: p, size: .zero), cornerRadius: 0)
        case .ellipse:
            kind = .ellipse(rect: CGRect(origin: p, size: .zero))
        case .polygon:
            kind = .polygon(rect: CGRect(origin: p, size: .zero), sides: 5,
                            starInnerRatio: nil)
        case .line:
            kind = .line(start: p, end: p, control: nil)
        case .arrow:
            kind = .arrow(ArrowPayload(start: p, end: p))
        default:
            return
        }
        let draft = DrawObject(kind: kind, style: shapeStyle)
        history.begin(scene)
        interaction = .drawing(draft: draft, anchor: p)
    }

    // MARK: - Draft updates

    private func updateDraft(_ draft: inout DrawObject, anchor: CGPoint, to p: CGPoint,
                             pressure: CGFloat, modifiers: EventModifiers) {
        switch draft.kind {
        case .stroke(var payload):
            // Drop samples closer than the minimum spacing: pointer jitter adds
            // points that cost time and make the smoothed curve wobble.
            guard StrokeGeometry.shouldAppend(p, to: payload.samples) else { return }
            payload.samples.append(StrokeSample(point: p, pressure: pressure,
                                                timestamp: Date().timeIntervalSince1970))
            draft.kind = .stroke(payload)

        case .rectangle(_, let radius):
            draft.kind = .rectangle(rect: dragRect(from: anchor, to: p, modifiers: modifiers),
                                    cornerRadius: radius)

        case .ellipse:
            draft.kind = .ellipse(rect: dragRect(from: anchor, to: p, modifiers: modifiers))

        case .polygon(_, let sides, let ratio):
            draft.kind = .polygon(rect: dragRect(from: anchor, to: p, modifiers: modifiers),
                                  sides: sides, starInnerRatio: ratio)

        case .line(let start, _, let control):
            draft.kind = .line(start: start,
                               end: constrainedEnd(from: anchor, to: p, modifiers: modifiers),
                               control: control)

        case .arrow(var payload):
            payload.end = constrainedEnd(from: anchor, to: p, modifiers: modifiers)
            draft.kind = .arrow(payload)

        default:
            break
        }
    }

    /// Shift constrains to a square; Option draws from the center.
    private func dragRect(from anchor: CGPoint, to p: CGPoint,
                          modifiers: EventModifiers) -> CGRect {
        var end = p
        if modifiers.contains(.shift) {
            let side = max(abs(p.x - anchor.x), abs(p.y - anchor.y))
            end = CGPoint(x: anchor.x + side * (p.x < anchor.x ? -1 : 1),
                          y: anchor.y + side * (p.y < anchor.y ? -1 : 1))
        }
        if modifiers.contains(.option) {
            let dx = abs(end.x - anchor.x), dy = abs(end.y - anchor.y)
            return CGRect(x: anchor.x - dx, y: anchor.y - dy, width: dx * 2, height: dy * 2)
        }
        return CGRect(dragFrom: anchor, to: end)
    }

    /// Shift snaps the direction to 15° increments.
    private func constrainedEnd(from anchor: CGPoint, to p: CGPoint,
                                modifiers: EventModifiers) -> CGPoint {
        guard modifiers.contains(.shift) else { return p }
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 0 else { return p }
        let step = CGFloat.pi / 12
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: anchor.x + cos(angle) * length,
                       y: anchor.y + sin(angle) * length)
    }

    // MARK: - Commit

    private func commitDraft(_ draft: DrawObject, anchor: CGPoint, end: CGPoint) {
        guard isCommittable(draft, anchor: anchor, end: end) else {
            // Degenerate draft: restore and push nothing, so a stray click does
            // not litter the document or the undo stack.
            if let restored = history.abort() { scene = restored }
            return
        }
        scene.addObject(draft)
        selection.select(draft.id)
        history.end(scene, name: "Draw \(tool.displayName)")
        onChange?(.done)
    }

    /// Reject drafts that are invisible or degenerate.
    private func isCommittable(_ draft: DrawObject, anchor: CGPoint, end: CGPoint) -> Bool {
        let bounds = draft.renderBounds
        // Fully outside the page in contained mode means invisible in export.
        if scene.canvas.mode.clipsToPage,
           !bounds.isNull, !bounds.intersects(scene.canvas.pageRect) {
            return false
        }
        switch draft.kind {
        case .rectangle(let r, _), .ellipse(let r), .polygon(let r, _, _):
            return hypot(r.width, r.height) >= 4
        case .line(let s, let e, _):
            return s.distance(to: e) >= 4
        case .arrow(let payload):
            return payload.start.distance(to: payload.end) >= 4
        case .stroke:
            return true    // a click is a legitimate dot
        case .text, .image, .filter, .polyline, .unknown:
            return true
        }
    }

    // MARK: - Selection helpers

    func topmostObject(at p: CGPoint, tolerance: CGFloat) -> DrawObject? {
        // Iterate top-down: later layers and later objects are visually on top.
        for layer in scene.layers.reversed() where layer.isVisible && !layer.isLocked {
            for object in layer.objects.reversed()
            where !object.isLocked && object.hitTest(p, tolerance: tolerance) {
                return object
            }
        }
        return nil
    }

    private func updateMarqueeSelection(from anchor: CGPoint, to current: CGPoint) {
        let rect = CGRect(dragFrom: anchor, to: current)
        // Marquee selects by INTERSECTION — touching is enough. This matches
        // Figma, Sketch, Excalidraw, and Illustrator. It deliberately differs
        // from click hit-testing, which uses the border band.
        var hits = Set<UUID>()
        for layer in scene.layers where layer.isVisible && !layer.isLocked {
            for object in layer.objects where !object.isLocked && !object.isHidden {
                let b = object.renderBounds
                if !b.isNull && b.intersects(rect) { hits.insert(object.id) }
            }
        }
        selection.objectIDs = hits
    }

    private func translateSelected(ids: Set<UUID>, by delta: CGPoint) {
        guard delta != .zero else { return }
        for id in ids {
            scene.withObject(id) { $0.translate(by: delta) }
        }
    }

    // MARK: - Commands

    /// Nudge, delete, style edits, and z-order all refuse while a mutating
    /// gesture is in flight: the single pre-gesture snapshot slot is occupied,
    /// and writing to it would corrupt history.
    private var canMutateHistory: Bool { !interaction.isMutatingGesture }

    func deleteSelection() {
        guard canMutateHistory, selection.hasObjects else { return }
        let before = scene
        scene.removeObjects(ids: selection.objectIDs)
        selection.clear()
        if history.record(from: before, to: scene, name: "Delete") { onChange?(.done) }
        surfaces.prune(keeping: scene.referencedSurfaceIDs)
    }

    func selectAll() {
        guard canMutateHistory else { return }
        selection.objectIDs = Set(scene.allObjects.filter { !$0.isLocked }.map(\.id))
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard canMutateHistory, selection.hasObjects else { return }
        let before = scene
        let delta = CGPoint(x: dx, y: dy)
        for id in selection.objectIDs {
            scene.withObject(id) { $0.translate(by: delta) }
        }
        if history.record(from: before, to: scene, name: "Nudge") { onChange?(.done) }
    }

    /// Esc cascades: cancel what is in flight, else deselect, else let the
    /// window handle it (close). Matching the reference's ordering.
    func escape() {
        if abortInFlightGesture() { return }
        if !selection.isEmpty { selection.clear() }
    }

    /// `[` and `]` step through a non-linear ladder, because a linear step
    /// feels far too slow at large sizes and far too coarse at small ones.
    func adjustBrushSize(step: Int) {
        let ladder: [CGFloat] = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128]
        let currentPt = brush.sizePx / scene.canvas.pixelsPerPoint
        // Nearest rung, so a size set by slider still steps sensibly.
        let index = ladder.enumerated()
            .min { abs($0.element - currentPt) < abs($1.element - currentPt) }?.offset ?? 0
        let next = (index + step).clamped(to: 0...(ladder.count - 1))
        brush.sizePx = scene.canvas.px(fromPoints: ladder[next])
        style.strokeWidthPx = brush.sizePx
    }

    func setCanvasBackground(_ background: CanvasBackground) {
        guard canMutateHistory else { return }
        let before = scene
        scene.canvas.background = background
        // Re-ink the DEFAULT for the next object only. Existing objects keep
        // their colors, and a color the user picked by hand is not overwritten.
        let ink = background.defaultInk
        if primaryColor == before.canvas.background.defaultInk {
            primaryColor = ink
        }
        if history.record(from: before, to: scene, name: "Canvas Background") {
            onChange?(.done)
        }
    }

    func setCanvasMode(_ mode: CanvasMode) {
        guard canMutateHistory, scene.canvas.mode != mode else { return }
        let before = scene
        scene.canvas.mode = mode
        if history.record(from: before, to: scene, name: "Canvas Mode") { onChange?(.done) }
    }

    // MARK: - Undo / redo

    /// `Cmd+Z` mid-gesture ABORTS the gesture rather than popping history; the
    /// next `Cmd+Z` pops. Returns true if the gesture was aborted.
    @discardableResult
    private func abortInFlightGesture() -> Bool {
        switch interaction {
        case .drawing, .marquee, .polyDrafting:
            interaction = .idle
            if let restored = history.abort() { scene = restored }
            return true
        case .draggingObjects, .resizing, .rotating:
            interaction = .idle
            if let restored = history.abort() { scene = restored }
            return true
        case .idle, .editingText, .panning:
            return false
        }
    }

    /// Resolve whatever is in flight when the tool changes — commit what is
    /// committable, discard what is not.
    private func resolveInFlightInteraction() {
        switch interaction {
        case .drawing, .polyDrafting, .marquee, .draggingObjects, .resizing, .rotating:
            abortInFlightGesture()
        case .idle, .editingText, .panning:
            break
        }
    }

    func undo() {
        if abortInFlightGesture() { return }
        guard let entry = history.undo(current: scene) else { return }
        apply(entry)
        onChange?(.undone)
    }

    func redo() {
        guard interaction.isIdle else { return }
        guard let entry = history.redo(current: scene) else { return }
        apply(entry)
        onChange?(.redone)
    }

    private func apply(_ entry: HistoryEntry) {
        switch entry {
        case .scene(let restored, _):
            scene = restored
            // A restored scene may not contain the previously selected objects.
            let live = Set(scene.allObjects.map(\.id))
            selection.objectIDs.formIntersection(live)
            surfaces.prune(keeping: scene.referencedSurfaceIDs)
        case .rasterPatch:
            break   // M6
        }
    }

    // MARK: - Viewport

    func zoom(by factor: CGFloat, about viewPoint: CGPoint) {
        transform.zoom(by: factor, about: viewPoint)
    }

    func pan(by delta: CGPoint) {
        transform.pan(by: delta)
    }

    func zoomToFit() {
        guard viewSize.width > 0 else { return }
        transform = .fit(pixelSize: scene.canvas.pixelSize.cgSize, in: viewSize,
                         pixelsPerPoint: scene.canvas.pixelsPerPoint)
    }

    func zoomToActualSize() {
        guard viewSize.width > 0 else { return }
        transform = .actualSize(pixelSize: scene.canvas.pixelSize.cgSize, in: viewSize,
                                pixelsPerPoint: scene.canvas.pixelsPerPoint)
    }

    /// Called when the canvas view first gets a size, so the document opens
    /// framed rather than at an arbitrary offset.
    func layoutIfNeeded(viewSize newSize: CGSize) {
        let wasUnset = viewSize == .zero
        viewSize = newSize
        if wasUnset, newSize.width > 0 { zoomToFit() }
    }

    // MARK: - Scene replacement (open / revert)

    func replaceScene(_ newScene: Scene, resetHistory: Bool = true) {
        scene = newScene
        selection.clear()
        interaction = .idle
        caches.invalidate()
        if resetHistory { history.clear() }
        surfaces.prune(keeping: scene.referencedSurfaceIDs)
        primaryColor = newScene.canvas.background.defaultInk
        style.strokeColor = primaryColor
        onChange?(.cleared)
    }
}

/// Modifier keys, captured on the same `NSEvent` as the pointer location so the
/// two can never race. Mirrors `NSEvent.ModifierFlags` without leaking AppKit
/// into the view model.
struct EventModifiers: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let shift = EventModifiers(rawValue: 1 << 0)
    static let option = EventModifiers(rawValue: 1 << 1)
    static let command = EventModifiers(rawValue: 1 << 2)
    static let control = EventModifiers(rawValue: 1 << 3)
}
