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
    /// The polygon-tool shape (from the shape library), used when a `.polygon`
    /// is dragged out.
    var shape: ShapeLibrary.Entry = ShapeLibrary.default

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

        case .resizing(let handle, let originals, _):
            // Recompute from the ORIGINALS every frame so a long drag never
            // accumulates float drift. The interaction state is unchanged.
            updateResize(handle: handle, originals: originals, to: p, modifiers: modifiers)

        case .rotating(let originals, let center, let startAngle):
            updateRotate(originals: originals, center: center, startAngle: startAngle,
                         to: p, modifiers: modifiers)

        case .idle, .polyDrafting, .editingText, .panning:
            break
        }
    }

    func pointerUp(at p: CGPoint) {
        switch interaction {
        case .drawing(let draft, let anchor):
            interaction = .idle
            commitDraft(draft, anchor: anchor, end: p)

        case .draggingObjects(_, _, let didDuplicate):
            interaction = .idle
            history.end(scene, name: didDuplicate ? "Duplicate" : "Move")
            onChange?(.done)

        case .resizing:
            interaction = .idle
            history.end(scene, name: "Resize")
            onChange?(.done)

        case .rotating:
            interaction = .idle
            history.end(scene, name: "Rotate")
            onChange?(.done)

        case .marquee:
            interaction = .idle

        case .idle, .polyDrafting, .editingText, .panning:
            interaction = .idle
        }
    }

    // MARK: - Gesture starts

    private func beginSelectGesture(at p: CGPoint, tolerance: CGFloat,
                                    modifiers: EventModifiers) {
        // 1. A handle on the current selection wins over any object hit, so a
        //    corner that overlaps another shape stays grabbable.
        if selection.hasObjects, let frame = selectionFrame,
           let handle = frame.handleHit(at: p, tolerance: handleTolerance) {
            beginHandleDrag(handle, frame: frame, at: p)
            return
        }

        // 2. Object hit. Cmd-click reaches the object BENEATH the selected one,
        //    cycling down the stack — Illustrator's select-behind.
        let hit = modifiers.contains(.command)
            ? objectBelowSelection(at: p, tolerance: tolerance)
            : topmostObject(at: p, tolerance: tolerance)

        if let hit {
            // Groups are atomic: clicking one member acts on the whole group.
            let group = scene.expandingGroups([hit.id])
            if modifiers.contains(.shift) {
                if selection.objectIDs.isSuperset(of: group) {
                    selection.objectIDs.subtract(group)
                } else {
                    selection.objectIDs.formUnion(group)
                }
            } else if !selection.objectIDs.contains(hit.id) {
                selection.objectIDs = group
            }
            guard selection.hasObjects else { return }
            history.begin(scene)
            // Option-drag leaves the originals in place and drags fresh copies.
            if modifiers.contains(.option) {
                let copies = insertDuplicates(of: selection.objectIDs, offset: .zero)
                if !copies.isEmpty { selection.objectIDs = copies }
                interaction = .draggingObjects(ids: selection.objectIDs, last: p,
                                               didDuplicate: true)
            } else {
                interaction = .draggingObjects(ids: selection.objectIDs, last: p,
                                               didDuplicate: false)
            }
        } else {
            if !modifiers.contains(.shift) { selection.clear() }
            interaction = .marquee(anchor: p, current: p)
        }
    }

    // MARK: - Handle drags (resize / rotate)

    /// The interactive frame for the current object selection, or nil. Rebuilt
    /// on demand from the live scene, so the handles track a shape as it is
    /// resized or rotated. CHROME ONLY — never enters `Scene`.
    var selectionFrame: SelectionFrame? {
        guard selection.hasObjects else { return nil }
        let objects = selection.objectIDs.compactMap { scene.object(with: $0) }
        return SelectionFrame.make(for: objects,
                                   rotateOffset: transform.canvasTolerance(viewPoints: 22))
    }

    /// Canvas-space slop for grabbing a handle — a touch larger than the general
    /// hit tolerance so the small squares stay easy to catch.
    private var handleTolerance: CGFloat { transform.canvasTolerance(viewPoints: 10) }

    private func beginHandleDrag(_ handle: Handle, frame: SelectionFrame, at p: CGPoint) {
        var originals: [UUID: DrawObject] = [:]
        for id in selection.objectIDs {
            if let object = scene.object(with: id) { originals[id] = object }
        }
        guard !originals.isEmpty else { return }
        history.begin(scene)
        if handle == .rotate {
            let startAngle = atan2(p.y - frame.center.y, p.x - frame.center.x)
            interaction = .rotating(originals: originals, center: frame.center,
                                    startAngle: startAngle)
        } else {
            interaction = .resizing(handle: handle, originals: originals,
                                    fixed: frame.box.oppositeCorner(handle))
        }
    }

    private func updateResize(handle: Handle, originals: [UUID: DrawObject],
                              to p: CGPoint, modifiers: EventModifiers) {
        // A single resizable shape uses its own anchored resize, which keeps the
        // opposite corner fixed in WORLD space even when rotated.
        if originals.count == 1, let (id, original) = originals.first,
           original.supportsHandleResize {
            scene.withObject(id) { $0 = original.resized(handle: handle, to: p) }
            return
        }
        // Everything else — a multi-selection, or a single freehand stroke —
        // scales as a group around the fixed opposite corner of the ORIGINAL box.
        let originalBox = originals.values.reduce(CGRect.null) {
            $0.unionIgnoringNull($1.bounds)
        }
        guard !originalBox.isNull, originalBox.width > 0.5, originalBox.height > 0.5
        else { return }
        let fixed = originalBox.oppositeCorner(handle)
        let newBox = originalBox.movingCorner(handle, to: p)
        let sx = max(newBox.width / originalBox.width, 0.01)
        let sy = max(newBox.height / originalBox.height, 0.01)
        for (id, original) in originals {
            scene.withObject(id) { $0 = original.scaled(sx: sx, sy: sy, around: fixed) }
        }
    }

    private func updateRotate(originals: [UUID: DrawObject], center: CGPoint,
                              startAngle: CGFloat, to p: CGPoint,
                              modifiers: EventModifiers) {
        let delta = atan2(p.y - center.y, p.x - center.x) - startAngle
        for (id, original) in originals where original.isRotatable {
            var newRotation = original.rotation + delta
            if modifiers.contains(.shift) {
                let step = CGFloat.pi / 12   // snap to 15°
                newRotation = (newRotation / step).rounded() * step
            }
            scene.withObject(id) { $0.rotation = newRotation }
        }
    }

    // MARK: - Duplication

    /// A fresh-identity copy of `object`, shifted by `offset`, with its group
    /// ids remapped through `groupRemap` so a duplicated group becomes its own
    /// group rather than rejoining the original.
    private func freshCopy(of object: DrawObject, offset: CGPoint,
                           groupRemap: inout [UUID: UUID]) -> DrawObject {
        var copy = DrawObject(id: UUID(), kind: object.kind,
                              style: object.style, rotation: object.rotation)
        copy.isLocked = object.isLocked
        copy.isHidden = object.isHidden
        copy.groupIDs = object.groupIDs.map { g in
            if let n = groupRemap[g] { return n }
            let n = UUID(); groupRemap[g] = n; return n
        }
        copy.erasedGeometry = object.erasedGeometry
        copy.unknownPayload = object.unknownPayload
        if offset != .zero { copy.translate(by: offset) }
        return copy
    }

    /// Insert copies of `ids` shifted by `offset`, returning the new ids. Pure
    /// scene mutation — the caller brackets history. Each copy stays in its
    /// original object's layer, so z-order is preserved.
    @discardableResult
    private func insertDuplicates(of ids: Set<UUID>, offset: CGPoint) -> Set<UUID> {
        var newIDs = Set<UUID>()
        var groupRemap: [UUID: UUID] = [:]
        // Bottom -> top, so duplicated objects keep their relative stacking.
        for original in scene.allObjects where ids.contains(original.id) {
            guard let layerID = scene.layerID(containing: original.id) else { continue }
            let copy = freshCopy(of: original, offset: offset, groupRemap: &groupRemap)
            scene.withLayer(layerID) { $0.objects.append(copy) }
            newIDs.insert(copy.id)
        }
        return newIDs
    }

    /// Insert external objects (from a paste) into the active layer with fresh
    /// identities, returning the new ids.
    @discardableResult
    private func insertPasted(_ objects: [DrawObject], offset: CGPoint) -> Set<UUID> {
        var newIDs = Set<UUID>()
        var groupRemap: [UUID: UUID] = [:]
        for object in objects {
            let copy = freshCopy(of: object, offset: offset, groupRemap: &groupRemap)
            scene.addObject(copy)
            newIDs.insert(copy.id)
        }
        return newIDs
    }

    // MARK: - Clipboard

    /// A small diagonal shift so a paste or duplicate lands offset from its
    /// source rather than hidden exactly on top of it.
    private var pasteOffset: CGPoint {
        let d = scene.canvas.px(fromPoints: 8)
        return CGPoint(x: d, y: d)
    }

    /// The selected objects in z-order (bottom -> top), so copy preserves their
    /// relative stacking on paste.
    private func orderedSelection() -> [DrawObject] {
        scene.allObjects.filter { selection.objectIDs.contains($0.id) }
    }

    func copySelection() {
        guard selection.hasObjects else { return }
        let objects = orderedSelection()
        let image = ExportService.renderObjects(objects, surfaces: surfaces,
                                                pixelsPerPoint: scene.canvas.pixelsPerPoint,
                                                colorSpaceName: scene.canvas.colorSpaceName)
        ObjectClipboard.write(objects, image: image,
                              pixelsPerPoint: scene.canvas.pixelsPerPoint)
    }

    func cut() {
        guard canMutateHistory, selection.hasObjects else { return }
        copySelection()
        removeSelected(name: "Cut")
    }

    func paste() { pasteObjects(offset: pasteOffset) }
    func pasteInPlace() { pasteObjects(offset: .zero) }

    private func pasteObjects(offset: CGPoint) {
        guard canMutateHistory, let objects = ObjectClipboard.read() else { return }
        let before = scene
        let newIDs = insertPasted(objects, offset: offset)
        guard !newIDs.isEmpty else { return }
        selection.objectIDs = newIDs
        if history.record(from: before, to: scene, name: "Paste") { onChange?(.done) }
    }

    func duplicateSelection() {
        guard canMutateHistory, selection.hasObjects else { return }
        let before = scene
        let newIDs = insertDuplicates(of: selection.objectIDs, offset: pasteOffset)
        guard !newIDs.isEmpty else { return }
        selection.objectIDs = newIDs
        if history.record(from: before, to: scene, name: "Duplicate") { onChange?(.done) }
    }

    // MARK: - Arrange

    /// Snapshot, mutate the scene through `body`, and push one named entry if it
    /// actually changed — the shape every arrange command shares.
    private func mutateSelected(_ name: String, minCount: Int = 1,
                                _ body: (inout Scene) -> Void) {
        guard canMutateHistory, selection.objectIDs.count >= minCount else { return }
        let before = scene
        body(&scene)
        if history.record(from: before, to: scene, name: name) { onChange?(.done) }
    }

    func bringForward() { mutateSelected("Bring Forward") { $0.reorder(self.selection.objectIDs, .forward) } }
    func sendBackward() { mutateSelected("Send Backward") { $0.reorder(self.selection.objectIDs, .backward) } }
    func bringToFront() { mutateSelected("Bring to Front") { $0.reorder(self.selection.objectIDs, .front) } }
    func sendToBack() { mutateSelected("Send to Back") { $0.reorder(self.selection.objectIDs, .back) } }

    func groupSelection() {
        mutateSelected("Group", minCount: 2) { scene in
            let groupID = UUID()
            for id in self.selection.objectIDs {
                scene.withObject(id) { $0.groupIDs.insert(groupID, at: 0) }
            }
        }
    }

    /// Remove the outermost group shared by the selection — one level of nesting,
    /// matching the "outermost first" group-id model.
    func ungroupSelection() {
        mutateSelected("Ungroup") { scene in
            let groups = Set(self.selection.objectIDs.compactMap {
                scene.object(with: $0)?.groupIDs.first
            })
            guard !groups.isEmpty else { return }
            for id in self.selection.objectIDs {
                scene.withObject(id) {
                    if let g = $0.groupIDs.first, groups.contains(g) { $0.groupIDs.removeFirst() }
                }
            }
        }
    }

    func alignSelection(_ kind: Scene.AlignKind) {
        mutateSelected("Align", minCount: 2) { $0.align(self.selection.objectIDs, kind) }
    }

    func distributeSelection(_ kind: Scene.DistributeKind) {
        mutateSelected("Distribute", minCount: 3) { $0.distribute(self.selection.objectIDs, kind) }
    }

    /// Lock the selection if any member is unlocked, else unlock it — one toggle
    /// with intuitive behavior on a mixed selection.
    func toggleLockSelection() {
        mutateSelected("Lock / Unlock") { scene in
            let lock = self.selection.objectIDs.contains {
                scene.object(with: $0)?.isLocked == false
            }
            for id in self.selection.objectIDs { scene.withObject(id) { $0.isLocked = lock } }
        }
    }

    func toggleHiddenSelection() {
        mutateSelected("Hide / Show") { scene in
            let hide = self.selection.objectIDs.contains {
                scene.object(with: $0)?.isHidden == false
            }
            for id in self.selection.objectIDs { scene.withObject(id) { $0.isHidden = hide } }
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
            kind = .polygon(rect: CGRect(origin: p, size: .zero), sides: shape.sides,
                            starInnerRatio: shape.starInnerRatio)
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
        hitsAt(p, tolerance: tolerance).first
    }

    /// Every object under `p`, topmost first (later layers and later objects are
    /// visually on top).
    private func hitsAt(_ p: CGPoint, tolerance: CGFloat) -> [DrawObject] {
        var result: [DrawObject] = []
        for layer in scene.layers.reversed() where layer.isVisible && !layer.isLocked {
            for object in layer.objects.reversed()
            where !object.isLocked && object.hitTest(p, tolerance: tolerance) {
                result.append(object)
            }
        }
        return result
    }

    /// Cmd-click select-behind: the object just beneath the currently selected
    /// one at this point, cycling from the bottom back to the top.
    private func objectBelowSelection(at p: CGPoint, tolerance: CGFloat) -> DrawObject? {
        let hits = hitsAt(p, tolerance: tolerance)
        guard !hits.isEmpty else { return nil }
        if let i = hits.firstIndex(where: { selection.objectIDs.contains($0.id) }) {
            return hits[(i + 1) % hits.count]
        }
        return hits.first
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
        // A marquee that touches one group member selects the whole group.
        selection.objectIDs = scene.expandingGroups(hits)
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

    func deleteSelection() { removeSelected(name: "Delete") }

    private func removeSelected(name: String) {
        guard canMutateHistory, selection.hasObjects else { return }
        let before = scene
        scene.removeObjects(ids: selection.objectIDs)
        selection.clear()
        if history.record(from: before, to: scene, name: name) { onChange?(.done) }
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

    /// Pick a library shape and arm the polygon tool to draw it.
    func selectShape(_ entry: ShapeLibrary.Entry) {
        shape = entry
        tool = .polygon
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
