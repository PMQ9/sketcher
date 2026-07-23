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
    /// The live brush stabilizer, reset at each stroke start. Transient input
    /// state, not UI state, so it is kept out of observation.
    @ObservationIgnored private var strokeStabilizer = OneEuroFilter()
    @ObservationIgnored private var lastStrokeTimestamp: TimeInterval = 0
    /// Which erasure the eraser tool performs. Shift+E cycles it.
    var eraserMode: EraserMode = .object

    // MARK: Region-tool state (M7)
    /// Shift+M draws an elliptical marquee instead of a rectangular one.
    var marqueeEllipse = false
    /// Shift+W is Select Similar (every matching pixel), not a contiguous flood.
    var wandContiguous = true
    /// Tolerance (0…1) for the wand and bucket; the wand's drag adjusts a copy.
    var pixelSelectionTolerance: CGFloat = 0.12
    /// The composite the wand floods, rendered once per gesture and reused while
    /// the tolerance drag re-floods it.
    @ObservationIgnored private var wandSource: CGImage?
    /// The region present when a select gesture began — the stable base every
    /// frame combines the fresh shape against, so union/subtract don't feed on
    /// their own partial output.
    @ObservationIgnored private var regionCombineBase: SelectionShape?
    /// The pre-lift surface of the layer a floating selection came from, kept so
    /// the drop can push ONE before→after patch (lift + move + drop = one entry).
    @ObservationIgnored private var floatingOrigin: (layerID: Layer.ID, image: CGImage)?
    /// Cached ant contours, keyed on the region, so a mask trace does not re-run
    /// every animation tick (the region changes only on a selection edit).
    @ObservationIgnored private var antCache: (region: SelectionShape, contours: [[CGPoint]])?
    /// The polygon-tool shape (from the shape library), used when a `.polygon`
    /// is dragged out.
    var shape: ShapeLibrary.Entry = ShapeLibrary.default
    /// Whether the redact tool blurs or pixelates (J vs Shift+J).
    var redactStyle: RedactStyle = .blur
    /// Corner radius (canvas px) for the next rectangle drawn.
    var shapeCornerRadiusPx: CGFloat = 0

    /// Text-tool defaults, inherited by the next text box. The dedicated text
    /// setters update BOTH the object being edited and these, so a change made
    /// while editing carries to the next box (Figma's model).
    var textFontName = "Helvetica Neue"
    var textFontSizePx: CGFloat = 48
    var textBold = false
    var textItalic = false
    var textUnderlined = false
    var textAlignment: TextAlignment = .left
    var textLineHeightMultiple: CGFloat = 1
    var textPlateEnabled = false
    /// A text box un-rotates to 0° for editing; this holds the angle to restore
    /// on commit (caret and IME geometry are wrong under a rotated parent).
    var editingOriginalRotation: CGFloat = 0

    var primaryColor: RGBAColor {
        didSet {
            style.strokeColor = primaryColor
            // Live-recolor the glyphs of the text being edited. The mutation
            // folds into the single open "Text" history entry (no separate push).
            if let id = interaction.editingTextID {
                scene.withObject(id) { $0.style.strokeColor = primaryColor }
            }
        }
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

        case .brush:
            beginStroke(at: p, modifiers: modifiers)

        case .eraser:
            beginEraserStroke(at: p)

        case .rectangle, .ellipse, .polygon, .line, .arrow:
            beginShape(at: p, modifiers: modifiers)

        case .eyedropper:
            if let color = sampleCanvas(at: p) { armColor(color) }

        case .redact:
            beginRedaction(at: p)

        case .text:
            beginTextTool(at: p, tolerance: tolerance)

        case .marquee, .lasso, .wand:
            beginRegionSelect(at: p, modifiers: modifiers)

        case .bucket:
            applyBucket(at: p, modifiers: modifiers)

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

        case .selectingRegion(let regionTool, let anchor, _, let mode):
            interaction = .selectingRegion(tool: regionTool, anchor: anchor,
                                           current: p, mode: mode)
            if regionTool == .wand { updateWandDrag(anchor: anchor, to: p, mode: mode) }

        case .selectingLasso(var points, let mode):
            if let last = points.last, last.distance(to: p) >= 1.5 { points.append(p) }
            interaction = .selectingLasso(points: points, mode: mode)

        case .movingFloating(let last):
            moveFloating(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            interaction = .movingFloating(last: p)

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

        case .selectingRegion(let regionTool, let anchor, let current, let mode):
            interaction = .idle
            commitRegionSelect(tool: regionTool, anchor: anchor, current: current, mode: mode)

        case .selectingLasso(let points, let mode):
            interaction = .idle
            commitLasso(points: points, mode: mode)

        case .movingFloating:
            interaction = .idle   // the float stays lifted until it is dropped

        case .editingText:
            break   // editing persists across a stray pointer-up; commit is explicit

        case .idle, .polyDrafting, .panning:
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
        guard canMutateHistory else { return }
        if selection.hasObjects {
            copySelection()
            removeSelected(name: "Cut")
        } else if selection.region != nil {
            cutPixelSelection()
        }
    }

    /// Objects on the pasteboard paste as objects; an external image pastes as
    /// an image object (D22). A pixel selection's copy is PNG/TIFF, so pasting
    /// it back also lands as an image object.
    func paste() {
        if ObjectClipboard.hasObjects { pasteObjects(offset: pasteOffset) }
        else { pasteImageObject(inPlace: false) }
    }
    func pasteInPlace() {
        if ObjectClipboard.hasObjects { pasteObjects(offset: .zero) }
        else { pasteImageObject(inPlace: true) }
    }

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
        seedStabilizer(at: p)
        history.begin(scene)
        interaction = .drawing(draft: draft, anchor: p)
    }

    /// Reset the live stabilizer to this stroke's start. The first sample passes
    /// through untouched (dt == 0) and seeds the filter.
    private func seedStabilizer(at p: CGPoint) {
        strokeStabilizer = OneEuroFilter.forStreamline(brush.streamline)
        lastStrokeTimestamp = Date().timeIntervalSince1970
        _ = strokeStabilizer.filter(p, dt: 0)
    }

    /// The eraser accumulates a stroke like the brush, shown as a faint neutral
    /// preview so the swept band is visible. It opens NO history bracket — the
    /// erasure is recorded once at commit (a scene diff, or a raster patch).
    private func beginEraserStroke(at p: CGPoint) {
        var previewStyle = ObjectStyle(strokeColor: RGBAColor(r: 0.5, g: 0.5, b: 0.5, a: 0.4))
        previewStyle.fill = .none
        var previewBrush = brush
        previewBrush.engine = .pen           // constant-width band, no taper
        previewBrush.simulatePressure = false
        let payload = StrokePayload(samples: [StrokeSample(point: p)], brush: previewBrush)
        seedStabilizer(at: p)
        interaction = .drawing(draft: DrawObject(kind: .stroke(payload), style: previewStyle),
                               anchor: p)
    }

    private func beginShape(at p: CGPoint, modifiers: EventModifiers) {
        var shapeStyle = style
        shapeStyle.strokeColor = primaryColor
        let kind: ObjectKind
        switch tool {
        case .rectangle:
            kind = .rectangle(rect: CGRect(origin: p, size: .zero),
                              cornerRadius: shapeCornerRadiusPx)
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
            // Stabilize first (kills tremor), then drop samples closer than the
            // minimum spacing: jitter points cost time and add nothing to the
            // outline. The filter still advances on skipped points, so its speed
            // estimate stays honest.
            let now = Date().timeIntervalSince1970
            let dt = lastStrokeTimestamp > 0 ? CGFloat(now - lastStrokeTimestamp) : 0
            lastStrokeTimestamp = now
            let smoothed = strokeStabilizer.filter(p, dt: dt)
            guard StrokeGeometry.shouldAppend(smoothed, to: payload.samples) else { return }
            payload.samples.append(StrokeSample(point: smoothed, pressure: pressure,
                                                timestamp: now))
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

        case .filter(var payload):
            payload.region = dragRect(from: anchor, to: p, modifiers: modifiers)
            draft.kind = .filter(payload)

        case .text(var payload):
            // Dragging out the box makes it fixed-width; a click (no drag) stays
            // auto-width, resolved in `enterTextEditing`.
            let box = dragRect(from: anchor, to: p, modifiers: modifiers)
            payload.origin = box.origin
            payload.boxSize = box.size
            payload.resize = .fixed
            draft.kind = .text(payload)

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
        // The eraser accumulates a stroke like the brush but never becomes an
        // object — its swept path drives an erasure at commit (D-M6).
        if tool == .eraser, case .stroke(let payload) = draft.kind {
            commitEraserStroke(payload)
            return
        }
        guard isCommittable(draft, anchor: anchor, end: end) else {
            // Degenerate draft: restore and push nothing, so a stray click does
            // not litter the document or the undo stack.
            if let restored = history.abort() { scene = restored }
            return
        }
        // A redaction is not an object — it bakes into pixels and destroys the
        // covered geometry (D11).
        if tool == .redact, case .filter(let payload) = draft.kind {
            applyRedaction(region: payload.region)
            return
        }
        // A text box is not finalized on mouse-up: it opens for editing. The
        // history bracket stays open until the edit commits (one "Text" entry).
        if case .text = draft.kind {
            enterTextEditing(from: draft, anchor: anchor)
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
        case .filter(let payload):
            // A redaction region must be big enough to be meaningful.
            return hypot(payload.region.width, payload.region.height) >= 6
        case .text, .image, .polyline, .unknown:
            return true
        }
    }

    // MARK: - Selection helpers

    func topmostObject(at p: CGPoint, tolerance: CGFloat) -> DrawObject? {
        hitsAt(p, tolerance: tolerance).first
    }

    /// The topmost editable text object under `p` — the text tool edits an
    /// existing box instead of stacking a new one on top of it.
    func topmostTextObject(at p: CGPoint, tolerance: CGFloat) -> DrawObject? {
        hitsAt(p, tolerance: tolerance).first {
            if case .text = $0.kind { return true }
            return false
        }
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

    func deleteSelection() {
        if selection.hasObjects { removeSelected(name: "Delete") }
        else if selection.region != nil { deleteSelectionPixels() }
    }

    private func removeSelected(name: String) {
        guard canMutateHistory, selection.hasObjects else { return }
        let before = scene
        scene.removeObjects(ids: selection.objectIDs)
        selection.clear()
        if history.record(from: before, to: scene, name: name) { onChange?(.done) }
        pruneSurfaces()
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

    /// Esc cascades: cancel a mid-drag gesture, else COMMIT a placed float
    /// (deselecting keeps the move — ⌘Z is the one that abandons it), else
    /// deselect, else let the window handle it (close).
    func escape() {
        if !interaction.isIdle { abortInFlightGesture(); return }
        if selection.floating != nil { dropFloating(); return }
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

    /// Shift+B cycles the brush preset (pen → pressure → pencil → …).
    func cycleBrushEngine() { brush.engine = brush.engine.next }

    /// Pick a library shape and arm the polygon tool to draw it.
    func selectShape(_ entry: ShapeLibrary.Entry) {
        shape = entry
        tool = .polygon
    }

    // MARK: - Colors

    /// Most-recently-used colors, newest first, de-duplicated, capped at 8.
    private(set) var recentColors: [RGBAColor] = []

    /// Swap primary and secondary (X).
    func swapColors() {
        let p = primaryColor
        primaryColor = secondaryColor
        secondaryColor = p
    }

    /// Reset to the classic black foreground / white background (D).
    func resetColors() {
        primaryColor = .black
        secondaryColor = .white
    }

    func rememberColor(_ color: RGBAColor) {
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > 8 { recentColors.removeLast(recentColors.count - 8) }
    }

    /// Arm `color` as the primary (for the next object) without touching the
    /// selection — the eyedropper's behavior.
    func armColor(_ color: RGBAColor) {
        primaryColor = color
        rememberColor(color)
    }

    /// Arm `color` AND recolor the selected objects' stroke, as one undo step —
    /// what clicking a swatch does when something is selected.
    func chooseColor(_ color: RGBAColor) {
        armColor(color)
        guard canMutateHistory, selection.hasObjects else { return }
        let before = scene
        for id in selection.objectIDs {
            scene.withObject(id) { $0.style.strokeColor = color }
        }
        if history.record(from: before, to: scene, name: "Color") { onChange?(.done) }
    }

    /// Sample the composited canvas at a canvas-pixel point (the eyedropper).
    /// Renders a 1×1 region through the real pipeline, so it reads exactly what
    /// exports — background, blends, and all.
    func sampleCanvas(at p: CGPoint) -> RGBAColor? {
        let rect = CGRect(x: p.x.rounded(.down), y: p.y.rounded(.down), width: 1, height: 1)
        guard let image = ExportService.renderRegion(scene, surfaces: surfaces, rect: rect)
        else { return nil }
        return image.firstPixelUnpremultiplied(colorSpace: scene.canvas.cgColorSpace)
    }

    // MARK: - Redaction (M4)

    private func beginRedaction(at p: CGPoint) {
        let draft = DrawObject(
            kind: .filter(FilterPayload(region: CGRect(origin: p, size: .zero),
                                        descriptor: redactionDescriptor(for: .zero))),
            style: ObjectStyle(strokeColor: nil))
        history.begin(scene)
        interaction = .drawing(draft: draft, anchor: p)
    }

    /// Redaction radius/block scales with the region so a small mask still
    /// obliterates its content and a large one is not absurdly heavy.
    private func redactionDescriptor(for region: CGRect) -> FilterDescriptor {
        let minDim = max(min(region.width, region.height), 1)
        switch redactStyle {
        case .blur: return .gaussianBlur(radiusPx: max(minDim / 8, 12))
        case .pixelate: return .pixelate(blockPx: max(minDim / 10, 12))
        }
    }

    /// Bake the redaction: blur/pixelate the region, DELETE every vector object
    /// fully inside it, clip partially-covered ones, and drop the opaque patch on
    /// top — all one undo entry. Destructive at commit (D11): the saved file
    /// keeps no geometry under the mask.
    private func applyRedaction(region: CGRect) {
        let clamped = region.integral.intersection(scene.canvas.pageRect)
        let descriptor = redactionDescriptor(for: clamped)
        guard clamped.width >= 2, clamped.height >= 2,
              let patch = Redaction.render(scene: scene, surfaces: surfaces,
                                           region: clamped, descriptor: descriptor) else {
            if let restored = history.abort() { scene = restored }
            return
        }
        let surface = surfaces.register(patch)
        // `allObjects` is a fresh snapshot, so mutating the scene inside the loop
        // is safe.
        for object in scene.allObjects {
            let b = object.bounds
            guard !b.isNull else { continue }
            if clamped.contains(b) {
                scene.removeObjects(ids: [object.id])
            } else if b.intersects(clamped) {
                scene.withObject(object.id) { $0.addErasedRect(clamped) }
            }
        }
        let payload = RasterPayload(
            surface: surface, rect: clamped,
            intrinsicPixelSize: PixelSize(width: Int(clamped.width), height: Int(clamped.height)))
        scene.addObject(DrawObject(kind: .image(payload), style: ObjectStyle(strokeColor: nil)))
        selection.clear()
        if history.end(scene, name: "Redact") { onChange?(.done) }
        pruneSurfaces()
    }

    /// Drop surfaces referenced by neither the live scene NOR any history entry
    /// NOR the current selection. Keeping the history's surfaces is what lets a
    /// redaction survive undo→redo; keeping the selection's is what stops a live
    /// wand mask or a lifted float being collected out from under the user.
    private func pruneSurfaces() {
        var keep = scene.referencedSurfaceIDs
            .union(history.referencedSurfaceIDs)
            .union(selection.referencedSurfaceIDs)
        // Keep the in-flight combine base too, or a Shift+wand drag re-flooding
        // each frame would collect the mask it is combining against.
        if case .mask(let id, _)? = regionCombineBase { keep.insert(id) }
        surfaces.prune(keeping: keep)
    }

    // MARK: - Style editing (inspector)

    /// The style the inspector displays: the topmost selected object's, or the
    /// armed-tool defaults when nothing is selected.
    var inspectorStyle: ObjectStyle {
        if let id = orderedSelection().last?.id, let object = scene.object(with: id) {
            return object.style
        }
        return style
    }

    /// True when a corner-radius control is relevant (a rectangle is selected,
    /// or the rectangle tool is armed).
    var inspectorHasRect: Bool {
        if selection.hasObjects {
            return selection.objectIDs.contains {
                if case .rectangle = scene.object(with: $0)?.kind { return true }
                return false
            }
        }
        return tool == .rectangle
    }

    var inspectorCornerRadiusPx: CGFloat {
        if selection.hasObjects {
            for id in selection.objectIDs {
                if case .rectangle(_, let radius) = scene.object(with: id)?.kind { return radius }
            }
        }
        return shapeCornerRadiusPx
    }

    /// Bracket a slider drag so its many value changes coalesce into ONE undo
    /// entry (only meaningful when a selection is being edited).
    func beginStyleEdit() {
        if selection.hasObjects { history.beginInteractive(scene) }
    }

    func endStyleEdit(_ name: String) {
        guard selection.hasObjects else { return }
        if history.endInteractive(scene, name: name) { onChange?(.done) }
    }

    /// Live style writes. With a selection they edit the objects (bracketed by
    /// begin/endStyleEdit for sliders, recorded directly for discrete controls);
    /// with none they edit the armed-tool defaults.
    func setStrokeWidthPx(_ width: CGFloat) {
        if selection.hasObjects {
            for id in selection.objectIDs { scene.withObject(id) { $0.style.strokeWidthPx = width } }
        } else {
            style.strokeWidthPx = width
            brush.sizePx = width
        }
    }

    func setOpacity(_ opacity: CGFloat) {
        if selection.hasObjects {
            for id in selection.objectIDs { scene.withObject(id) { $0.style.opacity = opacity } }
        } else {
            style.opacity = opacity
        }
    }

    /// Flip antialiasing — the pixel-art switch. Applies to the selection (one
    /// undo entry) or the armed-tool default.
    func toggleAntialias() {
        if selection.hasObjects {
            let before = scene
            let on = !(orderedSelection().last?.style.antialias ?? true)
            for id in selection.objectIDs { scene.withObject(id) { $0.style.antialias = on } }
            if history.record(from: before, to: scene, name: "Antialiasing") { onChange?(.done) }
        } else {
            style.antialias.toggle()
        }
    }

    func setCornerRadiusPx(_ radius: CGFloat) {
        if selection.hasObjects {
            for id in selection.objectIDs {
                scene.withObject(id) {
                    if case .rectangle(let rect, _) = $0.kind {
                        $0.kind = .rectangle(rect: rect, cornerRadius: radius)
                    }
                }
            }
        } else {
            shapeCornerRadiusPx = radius
        }
    }

    func setDash(_ dash: DashStyle) {
        if selection.hasObjects {
            let before = scene
            for id in selection.objectIDs { scene.withObject(id) { $0.style.dash = dash } }
            if history.record(from: before, to: scene, name: "Dash") { onChange?(.done) }
        } else {
            style.dash = dash
        }
    }

    /// Toggle a fill on/off for the selection (or the armed-tool default). A new
    /// fill uses the current primary color.
    func setFillEnabled(_ enabled: Bool) {
        let fill: Fill = enabled ? .solid(inspectorStyle.fill.color ?? primaryColor) : .none
        applyFill(fill)
    }

    /// Set the fill color of the selection (or the armed-tool default).
    func setFillColor(_ color: RGBAColor) { applyFill(.solid(color)) }

    private func applyFill(_ fill: Fill) {
        if selection.hasObjects {
            let before = scene
            for id in selection.objectIDs { scene.withObject(id) { $0.style.fill = fill } }
            if history.record(from: before, to: scene, name: "Fill") { onChange?(.done) }
        } else {
            style.fill = fill
        }
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
        case .selectingRegion, .selectingLasso:
            // Selection changes are not undoable; abandon the in-flight region
            // and revert to whatever was selected when the gesture began.
            interaction = .idle
            selection.region = regionCombineBase
            regionCombineBase = nil
            return true
        case .movingFloating:
            interaction = .idle
            abortFloating()
            return true
        case .editingText:
            // ⌘Z mid-edit abandons the edit (a brand-new box disappears; an
            // existing one reverts), consistent with mid-gesture abort.
            cancelTextEditing()
            return true
        case .idle, .panning:
            // A placed-but-undropped float: ⌘Z abandons it (restores the source).
            if selection.floating != nil { abortFloating(); return true }
            return false
        }
    }

    /// Resolve whatever is in flight when the tool changes — commit what is
    /// committable, discard what is not.
    private func resolveInFlightInteraction() {
        switch interaction {
        case .editingText:
            // Switching tools keeps the text, as clicking away does.
            commitTextEditing()
        case .drawing, .polyDrafting, .marquee, .draggingObjects, .resizing, .rotating,
             .selectingRegion, .selectingLasso, .movingFloating:
            abortInFlightGesture()
        case .idle, .panning:
            break
        }
        // A tool change drops a lifted-but-undropped float, as clicking away does.
        if selection.floating != nil { dropFloating() }
    }

    func undo() {
        if abortInFlightGesture() { return }
        guard let entry = history.undo(current: scene) else { return }
        apply(entry, undo: true)
        onChange?(.undone)
    }

    func redo() {
        guard interaction.isIdle else { return }
        guard let entry = history.redo(current: scene) else { return }
        apply(entry, undo: false)
        onChange?(.redone)
    }

    /// A `.scene` entry restores wholesale; a `.rasterPatch` composites the
    /// `before` tile on undo and the `after` tile on redo back into the layer's
    /// live surface — the direction is why this takes `undo`.
    private func apply(_ entry: HistoryEntry, undo: Bool) {
        switch entry {
        case .scene(let restored, _):
            scene = restored
            // A restored scene may not contain the previously selected objects.
            let live = Set(scene.allObjects.map(\.id))
            selection.objectIDs.formIntersection(live)
            pruneSurfaces()
        case .rasterPatch(let patch, _):
            applyRasterPatch(patch, useBefore: undo)
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
        pruneSurfaces()
        primaryColor = newScene.canvas.background.defaultInk
        style.strokeColor = primaryColor
        onChange?(.cleared)
    }
}

// MARK: - Text editing (M5)

/// The multiline-text editing lifecycle.
///
/// A text edit is one long-lived interaction, `Interaction.editingText(id)`,
/// bracketed by a SINGLE `history.begin`/`end` pair — so typing five lines,
/// toggling bold, and changing the font all collapse into one "Text" undo
/// entry. Every keystroke is written straight into the object's payload, so
/// CoreText redraws it live (the object is in `liveObjectIDs`); there is never a
/// second layout to pop at commit, which is the whole point of invariant T14.
///
/// The `NSTextView` sink (`TextEditingOverlay`) drives these methods: it reports
/// string changes through `updateEditingText`, and commits on resign / ⌘Return /
/// tool change. It never lays out visible glyphs — CoreText owns that.
///
/// Kept in this file (not a separate extension file) because it mutates the
/// file-private `scene` / `interaction` / `history`, exactly like redaction.
extension EditorViewModel {
    /// The text object being edited, or nil.
    var editingTextID: UUID? { interaction.editingTextID }

    var isEditingText: Bool { interaction.editingTextID != nil }

    /// True when text formatting applies to something: a live edit, or a text
    /// object in the selection. Drives the Format menu's enablement.
    var hasEditableText: Bool {
        if isEditingText { return true }
        return selection.objectIDs.contains {
            if case .text = scene.object(with: $0)?.kind { return true }
            return false
        }
    }

    /// The live object being edited (rotation is 0 while editing), for the
    /// overlay to position and style itself against.
    var editingTextObject: DrawObject? {
        guard let id = interaction.editingTextID else { return nil }
        return scene.object(with: id)
    }

    // MARK: Entering

    /// Text-tool mouse-down: commit any prior edit, then either edit the text
    /// box under the pointer or start dragging out a new one. A plain click
    /// (no drag) becomes an auto-width box; a drag becomes a fixed box — the
    /// distinction is resolved in `enterTextEditing`.
    func beginTextTool(at p: CGPoint, tolerance: CGFloat) {
        if isEditingText { commitTextEditing() }

        if let hit = topmostTextObject(at: p, tolerance: tolerance) {
            beginEditing(hit.id)
            return
        }

        let payload = TextPayload(
            origin: p, resize: .autoWidth,
            fontName: textFontName, fontSizePx: textFontSizePx,
            isBold: textBold, isItalic: textItalic, isUnderlined: textUnderlined,
            alignment: textAlignment, lineHeightMultiple: textLineHeightMultiple,
            plateColor: textPlateEnabled ? platePaperColor : nil)
        let draft = DrawObject(kind: .text(payload), style: newTextStyle)
        history.begin(scene)
        interaction = .drawing(draft: draft, anchor: p)
    }

    /// Called from `commitDraft` when a text-box drag finishes: fix up the sizing
    /// mode, insert the (still empty) object, and open it for editing. The history
    /// bracket opened in `beginTextTool` stays open until `commitTextEditing`.
    func enterTextEditing(from draft: DrawObject, anchor: CGPoint) {
        guard case .text(var payload) = draft.kind else { return }
        if let box = payload.boxSize, min(box.width, box.height) >= minTextDragPx {
            payload.resize = .fixed
        } else {
            // Too small to be a deliberate box: an auto-width box at the click.
            payload.boxSize = nil
            payload.resize = .autoWidth
            payload.origin = anchor
        }
        var object = draft
        object.kind = .text(payload)
        scene.addObject(object)
        editingOriginalRotation = 0
        selection.clear()
        interaction = .editingText(id: object.id)
    }

    /// Open an existing text object for editing. A rotated box un-rotates to 0°
    /// for the duration (caret/IME geometry is wrong under a rotated parent) and
    /// re-rotates on commit.
    func beginEditing(_ id: UUID) {
        guard let object = scene.object(with: id), case .text(let payload) = object.kind
        else { return }
        history.begin(scene)
        editingOriginalRotation = object.rotation
        if object.rotation != 0 {
            scene.withObject(id) { $0.rotation = 0 }
        }
        syncTextDefaults(from: payload)
        selection.clear()
        interaction = .editingText(id: id)
    }

    // MARK: Live typing

    /// Write the field editor's current string straight into the payload, so
    /// CoreText re-lays-out and redraws this frame. Folds into the open bracket.
    func updateEditingText(_ string: String) {
        guard let id = interaction.editingTextID else { return }
        scene.withObject(id) {
            guard case .text(var payload) = $0.kind else { return }
            guard payload.string != string else { return }
            payload.string = string
            $0.kind = .text(payload)
        }
    }

    // MARK: Committing / cancelling

    /// Finish editing, keeping the text. An empty box leaves nothing behind and
    /// is removed. Restores the pre-edit rotation. One "Text" undo entry.
    @discardableResult
    func commitTextEditing() -> Bool {
        guard let id = interaction.editingTextID else { return false }
        let rotation = editingOriginalRotation
        interaction = .idle
        editingOriginalRotation = 0

        let string: String
        if case .text(let payload)? = scene.object(with: id)?.kind {
            string = payload.string
        } else {
            string = ""
        }

        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Removing the box makes the scene equal the pre-edit snapshot for a
            // brand-new box (no entry pushed), or different for an existing one
            // the user cleared (one entry, so undo brings it back).
            scene.removeObjects(ids: [id])
            selection.clear()
            let changed = history.end(scene, name: "Text")
            if changed { onChange?(.done) }
            pruneSurfaces()
            return false
        }

        if rotation != 0 { scene.withObject(id) { $0.rotation = rotation } }
        selection.select(id)
        let changed = history.end(scene, name: "Text")
        if changed { onChange?(.done) }
        return changed
    }

    /// Abandon the edit: a new box disappears, an existing one reverts. Used by
    /// ⌘Z mid-edit.
    func cancelTextEditing() {
        guard interaction.editingTextID != nil else { return }
        interaction = .idle
        editingOriginalRotation = 0
        if let restored = history.abort() { scene = restored }
        selection.clear()
        pruneSurfaces()
    }

    // MARK: Text style

    /// The payload whose attributes the Format menu and inspector reflect: the
    /// object being edited, else the topmost selected text object.
    var representativeTextPayload: TextPayload? {
        if let id = interaction.editingTextID, case .text(let p)? = scene.object(with: id)?.kind {
            return p
        }
        for object in orderedSelection().reversed() {
            if case .text(let p) = object.kind { return p }
        }
        return nil
    }

    private var selectedTextIDs: [UUID] {
        selection.objectIDs.filter {
            if case .text = scene.object(with: $0)?.kind { return true }
            return false
        }
    }

    /// Apply a text-payload edit to the live targets — the object being edited
    /// (folded into the open "Text" entry), else the selected text objects.
    ///
    /// When a slider drag has an interactive bracket open (`beginStyleEdit`), the
    /// mutation is direct and the matching `endStyleEdit` records ONE coalesced
    /// entry; otherwise a discrete edit records immediately.
    private func mutateTextTargets(_ name: String, _ body: (inout TextPayload) -> Void) {
        func applyBody(_ id: UUID) {
            scene.withObject(id) {
                guard case .text(var payload) = $0.kind else { return }
                body(&payload)
                $0.kind = .text(payload)
            }
        }
        if let id = interaction.editingTextID {
            applyBody(id)
            return
        }
        let ids = selectedTextIDs
        guard canMutateHistory, !ids.isEmpty else { return }
        if history.isGestureInFlight {
            ids.forEach(applyBody)   // coalesced by the interactive bracket
            return
        }
        let before = scene
        ids.forEach(applyBody)
        if history.record(from: before, to: scene, name: name) { onChange?(.done) }
    }

    func toggleTextBold() {
        let value = !(representativeTextPayload?.isBold ?? textBold)
        textBold = value
        mutateTextTargets("Bold") { $0.isBold = value }
    }

    func toggleTextItalic() {
        let value = !(representativeTextPayload?.isItalic ?? textItalic)
        textItalic = value
        mutateTextTargets("Italic") { $0.isItalic = value }
    }

    func toggleTextUnderline() {
        let value = !(representativeTextPayload?.isUnderlined ?? textUnderlined)
        textUnderlined = value
        mutateTextTargets("Underline") { $0.isUnderlined = value }
    }

    func setTextAlignment(_ alignment: TextAlignment) {
        textAlignment = alignment
        mutateTextTargets("Align Text") { $0.alignment = alignment }
    }

    func setTextLineHeight(_ multiple: CGFloat) {
        let value = max(multiple, 0.5)
        textLineHeightMultiple = value
        mutateTextTargets("Line Height") { $0.lineHeightMultiple = value }
    }

    func setTextFontSize(_ px: CGFloat) {
        let value = max(px, 1)
        textFontSizePx = value
        mutateTextTargets("Font Size") { $0.fontSizePx = value }
    }

    func toggleTextPlate() {
        let on = !(representativeTextPayload?.plateColor != nil)
        textPlateEnabled = on
        let plate = on ? platePaperColor : nil
        mutateTextTargets("Text Plate") { $0.plateColor = plate }
    }

    /// Apply a font family and/or size (canvas pixels) and traits — the font
    /// panel and inspector family picker route here.
    func applyTextFont(name: String? = nil, sizePx: CGFloat? = nil,
                       bold: Bool? = nil, italic: Bool? = nil) {
        if let name { textFontName = name }
        if let sizePx { textFontSizePx = max(sizePx, 1) }
        if let bold { textBold = bold }
        if let italic { textItalic = italic }
        mutateTextTargets("Font") {
            if let name { $0.fontName = name }
            if let sizePx { $0.fontSizePx = max(sizePx, 1) }
            if let bold { $0.isBold = bold }
            if let italic { $0.isItalic = italic }
        }
    }

    // MARK: Text helpers

    private func syncTextDefaults(from payload: TextPayload) {
        textFontName = payload.fontName
        textFontSizePx = payload.fontSizePx
        textBold = payload.isBold
        textItalic = payload.isItalic
        textUnderlined = payload.isUnderlined
        textAlignment = payload.alignment
        textLineHeightMultiple = payload.lineHeightMultiple
        textPlateEnabled = payload.plateColor != nil
    }

    /// Style for a new text object: glyphs use `strokeColor`, no fill.
    private var newTextStyle: ObjectStyle {
        var style = ObjectStyle(strokeColor: primaryColor)
        style.fill = .none
        return style
    }

    /// A legibility plate that contrasts the current ink — light paper behind
    /// dark text, dark paper behind light text.
    private var platePaperColor: RGBAColor {
        primaryColor.luminance < 0.5
            ? RGBAColor(r: 1, g: 1, b: 1, a: 0.85)
            : RGBAColor(r: 0.10, g: 0.10, b: 0.11, a: 0.85)
    }

    /// Below this drag size a text placement is treated as a click (auto-width).
    private var minTextDragPx: CGFloat { scene.canvas.px(fromPoints: 8) }
}

// MARK: - Eraser & raster editing (M6)

/// The three eraser behaviors, cycled by Shift+E.
///
/// `object` deletes whole objects the stroke touches; `vector` clips the swept
/// region out of touched objects (partial erase, non-destructive); `pixel`
/// clears pixels on a raster layer. Pixel erase falls back to object erase when
/// the active layer holds no pixels, so the eraser always does something.
enum EraserMode: String, CaseIterable, Sendable {
    case object, vector, pixel

    var next: EraserMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var displayName: String {
        switch self {
        case .object: return "Erase Objects"
        case .vector: return "Erase (Partial)"
        case .pixel: return "Erase Pixels"
        }
    }
}

/// The eraser and the raster-layer edit path. Kept in this file (not a separate
/// extension) so it can drive the file-private `scene` / `history` / `surfaces`,
/// exactly like the redaction and text lifecycles.
extension EditorViewModel {
    func cycleEraserMode() { eraserMode = eraserMode.next }

    /// Dispatch a completed eraser stroke. No history bracket was opened at
    /// stroke start, so each branch records its own single entry (or nothing).
    func commitEraserStroke(_ payload: StrokePayload) {
        let points = payload.samples.map(\.point)
        let radius = max(payload.brush.sizePx / 2, 1)
        switch eraserMode {
        case .object: commitObjectErase(points: points, radius: radius)
        case .vector: commitVectorErase(points: points, radius: radius)
        case .pixel: commitPixelErase(points: points, radius: radius)
        }
        interaction = .idle
    }

    /// The eraser's swept region as a filled outline (constant width, round caps).
    private func eraserOutline(points: [CGPoint], radius: CGFloat) -> [CGPoint] {
        Freehand.outline(points.map { Freehand.InputPoint(point: $0, pressure: 1) },
                         options: Freehand.Options(size: radius * 2, thinning: 0,
                                                   smoothing: 0.35, simulatePressure: false))
    }

    // MARK: Object erase

    private func commitObjectErase(points: [CGPoint], radius: CGFloat) {
        var hits = Set<UUID>()
        for layer in scene.layers where layer.isEditable && layer.isVector {
            for object in layer.objects where !object.isLocked && !object.isHidden {
                if points.contains(where: { object.hitTest($0, tolerance: radius) }) {
                    hits.insert(object.id)
                }
            }
        }
        guard !hits.isEmpty else { return }
        let before = scene
        scene.removeObjects(ids: hits)
        selection.objectIDs.subtract(hits)
        if history.record(from: before, to: scene, name: "Erase") { onChange?(.done) }
        pruneSurfaces()
    }

    // MARK: Partial-vector erase

    private func commitVectorErase(points: [CGPoint], radius: CGFloat) {
        let outline = eraserOutline(points: points, radius: radius)
        guard outline.count >= 3 else { return }
        let sweptBounds = CGRect(containing: outline)
        let before = scene
        var changed = false
        for layer in scene.layers where layer.isEditable && layer.isVector {
            for object in layer.objects where !object.isLocked && !object.isHidden {
                guard object.renderBounds.intersects(sweptBounds),
                      points.contains(where: { object.hitTest($0, tolerance: radius) })
                else { continue }
                scene.withObject(object.id) { $0.addErasedPolygon(outline) }
                changed = true
            }
        }
        guard changed else { return }
        if history.record(from: before, to: scene, name: "Erase") { onChange?(.done) }
    }

    // MARK: Pixel erase (raster)

    private func commitPixelErase(points: [CGPoint], radius: CGFloat) {
        guard let i = scene.activeLayerIndex, scene.layers[i].isEditable,
              case .raster(let currentID) = scene.layers[i].content,
              let current = surfaces.image(currentID) else {
            // No raster target: still erase something rather than doing nothing.
            commitObjectErase(points: points, radius: radius)
            return
        }
        let outline = eraserOutline(points: points, radius: radius)
        guard outline.count >= 3,
              let after = RasterOps.erase(current, polygon: outline, canvas: scene.canvas)
        else { return }
        let dirty = RasterPatch.quantize(CGRect(containing: outline).insetBy(dx: -1, dy: -1),
                                         in: scene.canvas.pageRect)
        guard !dirty.isNull, dirty.width >= 1, dirty.height >= 1 else { return }
        commitRasterMutation(layerIndex: i, before: current, after: after,
                             dirty: dirty, name: "Erase")
    }

    // MARK: Raster patch commit + apply

    /// Turn a whole-surface before/after into a tile-quantized `RasterPatch`.
    ///
    /// The patch stores only MATERIALIZED tile crops (invariant 6), never the
    /// full surfaces and never `cropping(to:)` — that is the entire reason a
    /// long raster session stays under budget. The layer adopts the new full
    /// surface; the old one is dropped by `pruneSurfaces`.
    func commitRasterMutation(layerIndex i: Int, before current: CGImage,
                              after newFull: CGImage, dirty: CGRect, name: String) {
        guard i < scene.layers.count,
              let beforeTile = RasterOps.materialize(current, cropTo: dirty, canvas: scene.canvas),
              let afterTile = RasterOps.materialize(newFull, cropTo: dirty, canvas: scene.canvas)
        else { return }

        let beforeID = surfaces.register(beforeTile)
        let afterID = surfaces.register(afterTile)
        let newFullID = surfaces.register(newFull)
        let layerID = scene.layers[i].id
        scene.withLayer(layerID) { $0.content = .raster(newFullID) }

        let bytes = beforeTile.height * beforeTile.bytesPerRow
            + afterTile.height * afterTile.bytesPerRow
        history.push(.rasterPatch(RasterPatch(layerID: layerID, rect: dirty,
                                              before: beforeID, after: afterID,
                                              byteCount: bytes), name: name))
        onChange?(.done)
        pruneSurfaces()
    }

    /// Composite a patch's tile back into the layer's live surface. On undo the
    /// `before` tile, on redo the `after` tile — outside the tile the two
    /// surfaces are identical, so replacing just the tile restores exactly.
    private func applyRasterPatch(_ patch: RasterPatch, useBefore: Bool) {
        guard let i = scene.index(of: patch.layerID),
              case .raster(let currentID) = scene.layers[i].content,
              let currentFull = surfaces.image(currentID),
              let tile = surfaces.image(useBefore ? patch.before : patch.after),
              let restored = RasterOps.compositeTile(tile, into: currentFull,
                                                     at: patch.rect, canvas: scene.canvas)
        else { return }
        let newID = surfaces.register(restored)
        scene.withLayer(patch.layerID) { $0.content = .raster(newID) }
        pruneSurfaces()
    }
}

// MARK: - Layers (M6)

/// The layer stack API the layers panel drives. Every mutation is one named
/// history entry (opacity coalesces its slider drag). Rasterize / merge / flatten
/// route content through the ONE `RasterOps` renderer, so a baked layer matches
/// its on-screen look exactly, and register their result in `SurfaceStore`.
///
/// Same-file, like the other lifecycles: it needs the file-private `scene`,
/// `history`, `pruneSurfaces`, and `freshCopy`.
extension EditorViewModel {
    var layers: [Layer] { scene.layers }
    var activeLayerID: Layer.ID { scene.activeLayerID }
    var activeLayer: Layer? { scene.activeLayer }
    var canMergeDown: Bool { (scene.activeLayerIndex ?? 0) > 0 }

    private func nextLayerName() -> String { "Layer \(scene.layers.count + 1)" }

    func setActiveLayer(_ id: Layer.ID) {
        guard canMutateHistory, scene.activeLayerID != id else { return }
        scene.activeLayerID = id
    }

    func addVectorLayer() { addLayer(.vector(named: nextLayerName())) }

    func addRasterLayer() {
        guard let blank = RasterOps.blank(scene.canvas) else { return }
        addLayer(Layer(name: nextLayerName(), content: .raster(surfaces.register(blank))))
    }

    private func addLayer(_ layer: Layer) {
        guard canMutateHistory else { return }
        let before = scene
        scene.insertLayer(layer, above: scene.activeLayerID)
        if history.record(from: before, to: scene, name: "New Layer") { onChange?(.done) }
    }

    func duplicateActiveLayer() {
        guard canMutateHistory, let src = scene.activeLayer else { return }
        let before = scene
        var copy: Layer
        switch src.content {
        case .raster(let id):
            // Surfaces are immutable, so both layers can share the same handle —
            // prune keeps it while either references it.
            copy = Layer(name: src.name + " copy", content: .raster(id))
        case .vector(let objects):
            var remap: [UUID: UUID] = [:]
            let fresh = objects.map { freshCopy(of: $0, offset: .zero, groupRemap: &remap) }
            copy = Layer(name: src.name + " copy", content: .vector(fresh))
        }
        copy.opacity = src.opacity
        copy.blend = src.blend
        copy.isVisible = src.isVisible
        copy.isLocked = src.isLocked
        scene.insertLayer(copy, above: src.id)
        if history.record(from: before, to: scene, name: "Duplicate Layer") { onChange?(.done) }
    }

    func deleteActiveLayer() {
        guard canMutateHistory, scene.layers.count > 1 else { return }
        let before = scene
        scene.removeLayer(scene.activeLayerID)
        selection.objectIDs.formIntersection(Set(scene.allObjects.map(\.id)))
        if history.record(from: before, to: scene, name: "Delete Layer") { onChange?(.done) }
        pruneSurfaces()
    }

    /// Bake a vector layer's objects into a single raster surface, keeping the
    /// layer's own opacity and blend.
    func rasterizeActiveLayer() {
        guard canMutateHistory, let idx = scene.activeLayerIndex, scene.layers[idx].isVector,
              let image = RasterOps.rasterizeContent(of: scene.layers[idx], in: scene,
                                                     surfaces: surfaces) else { return }
        let before = scene
        let id = surfaces.register(image)
        scene.withLayer(scene.layers[idx].id) { $0.content = .raster(id) }
        selection.objectIDs.formIntersection(Set(scene.allObjects.map(\.id)))
        if history.record(from: before, to: scene, name: "Rasterize Layer") { onChange?(.done) }
        pruneSurfaces()
    }

    /// Merge the active layer into the one below it, compositing both with their
    /// opacity and blend into one raster layer.
    func mergeDownActiveLayer() {
        guard canMutateHistory, let idx = scene.activeLayerIndex, idx > 0,
              let image = RasterOps.flatten([scene.layers[idx - 1], scene.layers[idx]],
                                            in: scene, surfaces: surfaces) else { return }
        let before = scene
        let name = scene.layers[idx - 1].name
        let merged = Layer(name: name, content: .raster(surfaces.register(image)))
        scene.layers.replaceSubrange((idx - 1)...idx, with: [merged])
        scene.activeLayerID = merged.id
        selection.objectIDs.formIntersection(Set(scene.allObjects.map(\.id)))
        if history.record(from: before, to: scene, name: "Merge Down") { onChange?(.done) }
        pruneSurfaces()
    }

    /// Collapse every layer into one raster layer.
    func flattenImage() {
        guard canMutateHistory, scene.layers.count > 1,
              let image = RasterOps.flatten(scene.layers, in: scene,
                                            surfaces: surfaces) else { return }
        let before = scene
        let flat = Layer(name: "Flattened", content: .raster(surfaces.register(image)))
        scene.layers = [flat]
        scene.activeLayerID = flat.id
        selection.clear()
        if history.record(from: before, to: scene, name: "Flatten Image") { onChange?(.done) }
        pruneSurfaces()
    }

    // MARK: Layer properties

    func setLayerVisible(_ id: Layer.ID, _ visible: Bool) {
        recordLayerEdit("Layer Visibility", id) { $0.isVisible = visible }
    }
    func setLayerLocked(_ id: Layer.ID, _ locked: Bool) {
        recordLayerEdit("Layer Lock", id) { $0.isLocked = locked }
    }
    func setLayerName(_ id: Layer.ID, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        recordLayerEdit("Rename Layer", id) { $0.name = trimmed }
    }
    func setLayerBlend(_ id: Layer.ID, _ blend: CGBlendMode) {
        recordLayerEdit("Blend Mode", id) { $0.blend = blend }
    }

    private func recordLayerEdit(_ name: String, _ id: Layer.ID,
                                 _ body: (inout Layer) -> Void) {
        guard canMutateHistory else { return }
        let before = scene
        scene.withLayer(id, body)
        if history.record(from: before, to: scene, name: name) { onChange?(.done) }
    }

    /// Opacity is a slider: its drag coalesces into one entry.
    func setLayerOpacity(_ id: Layer.ID, _ opacity: CGFloat) {
        scene.withLayer(id) { $0.opacity = min(max(opacity, 0), 1) }
    }
    func beginLayerOpacityEdit() { history.beginInteractive(scene) }
    func endLayerOpacityEdit() {
        if history.endInteractive(scene, name: "Layer Opacity") { onChange?(.done) }
    }

    // MARK: Reorder

    func raiseActiveLayer() { swapActive(by: 1) }
    func lowerActiveLayer() { swapActive(by: -1) }

    private func swapActive(by delta: Int) {
        guard canMutateHistory, let idx = scene.activeLayerIndex,
              scene.layers.indices.contains(idx + delta) else { return }
        let before = scene
        scene.layers.swapAt(idx, idx + delta)
        if history.record(from: before, to: scene, name: "Reorder Layer") { onChange?(.done) }
    }
}

// MARK: - Region selection & floating pixels (M7)

/// Marquee / lasso / wand region selection and the lift → transform → drop
/// floating-pixels lifecycle. Same-file, like the eraser / text / layer
/// lifecycles: it drives the file-private `scene` / `history` / `surfaces` /
/// `interaction`.
///
/// A pixel region lives on `selection.region` — never in `Scene`, never
/// undoable. Lifting turns it into `selection.floating`: the source layer's
/// surface is swapped to a cleared copy immediately (so the move reads right on
/// screen) but NO history entry is pushed. The original surface is stashed in
/// `floatingOrigin`, and the drop pushes ONE before→after `RasterPatch`, so
/// lift + move + drop collapse into a single undo step.
extension EditorViewModel {

    // MARK: Derived state for the overlay

    /// Whether the marching-ants overlay should be present (a committed region,
    /// a lifted float, or an in-progress region drag).
    var showsSelectionOverlay: Bool {
        selection.region != nil || selection.floating != nil || interaction.isSelectingRegion
    }

    /// The committed selection's ant contours, in canvas pixels. A floating
    /// selection's outline is four transformed corners (recomputed live, cheap);
    /// a committed region is cached, so a mask's marching-squares trace runs only
    /// when the region actually changes, not every animation frame.
    func antContours() -> [[CGPoint]] {
        if selection.floating != nil {
            return MarchingAnts.contours(for: selection, canvas: scene.canvas, surfaces: surfaces)
        }
        guard let region = selection.region else { return [] }
        if let cache = antCache, cache.region == region { return cache.contours }
        let contours = MarchingAnts.contours(for: selection, canvas: scene.canvas, surfaces: surfaces)
        antCache = (region, contours)
        return contours
    }

    // MARK: Region creation

    func beginRegionSelect(at p: CGPoint, modifiers: EventModifiers) {
        let mode = CombineMode(shift: modifiers.contains(.shift),
                               option: modifiers.contains(.option))
        // A plain click/drag INSIDE the current selection lifts and moves it —
        // but only when there are pixels to lift (active raster layer). On a
        // vector layer the pixel tools only ever select (D38-style fallback).
        if mode == .replace, selection.floating == nil,
           activeRasterSurface != nil, selectionContains(p) {
            beginFloatingDrag(at: p)
            return
        }
        // Starting a brand-new selection drops any placed float first.
        if selection.floating != nil { dropFloating() }
        regionCombineBase = selection.region

        switch tool {
        case .lasso:
            interaction = .selectingLasso(points: [p], mode: mode)
        case .wand:
            wandSource = RasterOps.render(scene, surfaces: surfaces)
            commitWand(seed: p, tolerance: pixelSelectionTolerance, mode: mode)
            interaction = .selectingRegion(tool: .wand, anchor: p, current: p, mode: mode)
        default:   // marquee / elliptical marquee
            interaction = .selectingRegion(tool: .marquee, anchor: p, current: p, mode: mode)
        }
    }

    /// Rectangular / elliptical marquee, committed on mouse-up.
    func commitRegionSelect(tool: Tool, anchor: CGPoint, current: CGPoint, mode: CombineMode) {
        defer { regionCombineBase = nil; wandSource = nil }
        if tool == .wand { return }   // the wand already set the region live
        let rect = CGRect(dragFrom: anchor, to: current).intersection(scene.canvas.pageRect)
        guard rect.width >= 1, rect.height >= 1 else {
            clickToDeselect(mode: mode)
            return
        }
        let shape: SelectionShape = marqueeEllipse ? .ellipse(rect) : .rect(rect)
        setRegion(combine(regionCombineBase, shape, mode))
    }

    /// Freehand lasso, committed on mouse-up.
    func commitLasso(points: [CGPoint], mode: CombineMode) {
        defer { regionCombineBase = nil }
        guard points.count >= 3 else { clickToDeselect(mode: mode); return }
        setRegion(combine(regionCombineBase, .polygon(points: points, evenOdd: false), mode))
    }

    /// The wand's live tolerance drag: horizontal distance from the seed widens
    /// or narrows tolerance, re-flooding the cached composite (Procreate's feel).
    func updateWandDrag(anchor: CGPoint, to p: CGPoint, mode: CombineMode) {
        let tolerance = max(0.01, min(1, pixelSelectionTolerance + (p.x - anchor.x) * 0.001))
        commitWand(seed: anchor, tolerance: tolerance, mode: mode)
    }

    private func commitWand(seed: CGPoint, tolerance: CGFloat, mode: CombineMode) {
        guard let source = wandSource,
              let regionImage = FloodFill.region(in: source, seed: seed, tolerance: tolerance,
                                                 contiguous: wandContiguous,
                                                 canvas: scene.canvas) else { return }
        let bounds = MaskOps.nonEmptyBounds(regionImage, canvas: scene.canvas)
        guard !bounds.isNull, !bounds.isEmpty else { return }
        let wand = SelectionShape.mask(surfaces.register(regionImage), bounds: bounds)
        setRegion(combine(regionCombineBase, wand, mode))
    }

    /// A click with no drag: clear the selection (replace mode) or leave the
    /// base untouched (a mis-started combine).
    private func clickToDeselect(mode: CombineMode) {
        if mode == .replace {
            selection.region = nil
            selection.featherPx = 0
        } else {
            selection.region = regionCombineBase
        }
        pruneSurfaces()
    }

    private func combine(_ base: SelectionShape?, _ shape: SelectionShape,
                         _ mode: CombineMode) -> SelectionShape? {
        MaskOps.combine(base, shape, mode: mode, canvas: scene.canvas, surfaces: surfaces)
    }

    /// A pixel region replaces any object selection (they are two different
    /// domains, one keystroke apart — the `V` vs `M`/`Q`/`W` rule).
    private func setRegion(_ region: SelectionShape?) {
        selection.objectIDs.removeAll()
        selection.region = region
        pruneSurfaces()
    }

    // MARK: Region commands

    func selectAllPixels() { setRegion(.rect(scene.canvas.pageRect)) }

    func invertSelection() {
        guard let region = selection.region else { return }
        setRegion(MaskOps.invert(region, canvas: scene.canvas, surfaces: surfaces))
    }

    func growSelection() { morphSelection(byPoints: 3) }
    func shrinkSelection() { morphSelection(byPoints: -3) }

    private func morphSelection(byPoints points: CGFloat) {
        guard let region = selection.region else { return }
        let deltaPx = scene.canvas.px(fromPoints: points)
        setRegion(MaskOps.morphology(region, deltaPx: deltaPx,
                                     canvas: scene.canvas, surfaces: surfaces) ?? region)
    }

    func featherSelection() {
        guard let region = selection.region else { return }
        let radiusPx = scene.canvas.px(fromPoints: 4)
        selection.featherPx = radiusPx
        setRegion(MaskOps.feather(region, radiusPx: radiusPx,
                                  canvas: scene.canvas, surfaces: surfaces) ?? region)
    }

    // MARK: Fill / clear the region

    /// Fill the selection with a color, clipped through the region — Fill
    /// Selection (Opt/Cmd+Delete). Targets the active raster layer; on a vector
    /// layer it is a no-op (run Rasterize Layer first, matching the eraser).
    func fillSelection(with color: RGBAColor) {
        guard canMutateHistory, let region = selection.region,
              let raster = activeRasterSurface,
              let filled = paintRegion(color, region: region, onto: raster.image) else { return }
        let dirty = RasterPatch.quantize(region.bounds.insetBy(dx: -1, dy: -1),
                                         in: scene.canvas.pageRect)
        commitRasterMutation(layerIndex: raster.index, before: raster.image, after: filled,
                             dirty: dirty, name: "Fill Selection")
    }

    /// Clear the selected pixels to transparent — Delete with a region active.
    func deleteSelectionPixels() {
        guard canMutateHistory, let region = selection.region,
              let raster = activeRasterSurface,
              let cleared = clearRegion(in: raster.image, region: region) else { return }
        let dirty = RasterPatch.quantize(region.bounds.insetBy(dx: -1, dy: -1),
                                         in: scene.canvas.pageRect)
        commitRasterMutation(layerIndex: raster.index, before: raster.image, after: cleared,
                             dirty: dirty, name: "Clear")
    }

    // MARK: Floating pixels — lift / move / drop

    /// Lift the selected pixels off the active raster layer into a live float.
    /// The layer's surface is swapped to a cleared copy WITHOUT a history push;
    /// the original is stashed so the drop can record one patch.
    private func beginFloatingDrag(at p: CGPoint) {
        guard let region = selection.region, let raster = activeRasterSurface else { return }
        let bounds = region.bounds.integral.intersection(scene.canvas.pageRect)
        guard bounds.width >= 1, bounds.height >= 1,
              let floatImage = liftPixels(from: raster.image, region: region, bounds: bounds),
              let cleared = clearRegion(in: raster.image, region: region) else { return }

        floatingOrigin = (layerID: scene.layers[raster.index].id, image: raster.image)
        let clearedID = surfaces.register(cleared)
        scene.withLayer(scene.layers[raster.index].id) { $0.content = .raster(clearedID) }
        selection.floating = FloatingPixels(
            surface: surfaces.register(floatImage), sourceRect: bounds,
            transform: .identity, originalTransform: .identity,
            liftedFromLayer: scene.layers[raster.index].id, liftMode: .cut)
        interaction = .movingFloating(last: p)
        pruneSurfaces()
    }

    func moveFloating(by delta: CGPoint) {
        guard var floating = selection.floating else { return }
        floating.transform = floating.transform
            .concatenating(CGAffineTransform(translationX: delta.x, y: delta.y))
        selection.floating = floating
    }

    /// Composite the float back down as ONE patch: pre-lift → (source cleared +
    /// float placed). Return/tool-change/click-away call this.
    func dropFloating() {
        guard let floating = selection.floating, let origin = floatingOrigin,
              let index = scene.index(of: origin.layerID),
              case .raster(let currentID) = scene.layers[index].content,
              let cleared = surfaces.image(currentID),
              let floatImage = surfaces.image(floating.surface),
              let dropped = compositeFloat(floatImage, transform: floating.transform,
                                           sourceRect: floating.sourceRect, onto: cleared) else {
            selection.floating = nil
            floatingOrigin = nil
            return
        }
        let dirty = RasterPatch.quantize(
            floating.sourceRect.union(transformedBounds(floating)).insetBy(dx: -1, dy: -1),
            in: scene.canvas.pageRect)
        selection.floating = nil
        selection.region = nil
        floatingOrigin = nil
        // before == the ORIGINAL surface, so undo lands on the un-moved image.
        commitRasterMutation(layerIndex: index, before: origin.image, after: dropped,
                             dirty: dirty, name: "Move Selection")
    }

    /// Return the source surface to its pre-lift state — ⌘Z / Esc mid-float.
    func abortFloating() {
        defer { selection.floating = nil; floatingOrigin = nil }
        guard let origin = floatingOrigin, scene.index(of: origin.layerID) != nil else { return }
        let id = surfaces.register(origin.image)
        scene.withLayer(origin.layerID) { $0.content = .raster(id) }
        selection.region = nil
        pruneSurfaces()
    }

    /// Return / Enter commits a lifted float.
    func commitFloating() { if selection.floating != nil { dropFloating() } }

    // MARK: Pixel clipboard

    /// Copy the selected pixels (the composite within the region) as PNG + TIFF.
    func copyPixelSelection() {
        guard let image = selectionImage() else { return }
        PasteboardWriter.write(image, pixelsPerPoint: scene.canvas.pixelsPerPoint)
    }

    /// Cut: copy, then clear the region on the active raster layer.
    func cutPixelSelection() {
        copyPixelSelection()
        deleteSelectionPixels()
    }

    /// Paste an external image as an `.image` object (D22): selectable and
    /// movable with the `V` tool, one undo entry, no raster-layer requirement.
    /// Returns false if the pasteboard carries no image.
    @discardableResult
    func pasteImageObject(inPlace: Bool) -> Bool {
        guard canMutateHistory, let image = ObjectClipboard.readImage() else { return false }
        let size = PixelSize(width: image.width, height: image.height)
        let id = surfaces.register(image)
        let page = scene.canvas.pageRect
        let origin = inPlace
            ? CGPoint(x: page.midX - CGFloat(size.width) / 2, y: page.midY - CGFloat(size.height) / 2)
            : CGPoint(x: page.midX - CGFloat(size.width) / 2 + pasteOffset.x,
                      y: page.midY - CGFloat(size.height) / 2 + pasteOffset.y)
        let rect = CGRect(origin: origin, size: CGSize(width: size.width, height: size.height))
        let payload = RasterPayload(surface: id, rect: rect, intrinsicPixelSize: size)
        let before = scene
        let object = DrawObject(kind: .image(payload), style: ObjectStyle(strokeColor: nil))
        scene.addObject(object)
        selection.region = nil
        selection.objectIDs = [object.id]
        if history.record(from: before, to: scene, name: "Paste Image") { onChange?(.done) }
        pruneSurfaces()
        return true
    }

    // MARK: Bucket fill

    /// The bucket. On a vector shape's interior it sets that shape's fill —
    /// resolution-independent and non-destructive, the DEFAULT bucket behavior.
    /// Otherwise it flood-fills the active raster layer with the SAME
    /// `FloodFill.region` the wand uses, so their tolerance can never diverge.
    func applyBucket(at p: CGPoint, modifiers: EventModifiers) {
        guard canMutateHistory else { return }
        if let target = closedShapeHit(at: p) {
            fillVectorObject(target)
            return
        }
        fillRasterBucket(at: p)
    }

    private func fillVectorObject(_ id: UUID) {
        let before = scene
        scene.withObject(id) { $0.style.fill = .solid(self.primaryColor) }
        selection.objectIDs = [id]
        selection.region = nil
        if history.record(from: before, to: scene, name: "Fill") { onChange?(.done) }
    }

    private func fillRasterBucket(at p: CGPoint) {
        guard let raster = activeRasterSurface,
              let regionImage = FloodFill.region(in: raster.image, seed: p,
                                                 tolerance: pixelSelectionTolerance,
                                                 contiguous: true, canvas: scene.canvas) else { return }
        let bounds = MaskOps.nonEmptyBounds(regionImage, canvas: scene.canvas)
        guard !bounds.isNull, !bounds.isEmpty else { return }
        let region = SelectionShape.mask(surfaces.register(regionImage), bounds: bounds)
        guard let filled = paintRegion(primaryColor, region: region, onto: raster.image) else { return }
        let dirty = RasterPatch.quantize(bounds.insetBy(dx: -1, dy: -1), in: scene.canvas.pageRect)
        commitRasterMutation(layerIndex: raster.index, before: raster.image, after: filled,
                             dirty: dirty, name: "Bucket Fill")
    }

    /// The topmost fillable closed shape whose INTERIOR contains `p` (bucket uses
    /// interior, unlike the border-band hit test that lets you click through).
    private func closedShapeHit(at p: CGPoint) -> UUID? {
        for layer in scene.layers.reversed() where layer.isEditable && layer.isVector {
            for object in layer.objects.reversed()
            where !object.isLocked && !object.isHidden && objectInteriorContains(object, p) {
                return object.id
            }
        }
        return nil
    }

    private func objectInteriorContains(_ object: DrawObject, _ p: CGPoint) -> Bool {
        switch object.kind {
        case .rectangle, .ellipse, .polygon: break
        case .polyline(_, let closed) where closed: break
        default: return false
        }
        let local = object.rotation != 0
            ? p.rotated(around: object.rotationCenter, by: -object.rotation) : p
        guard let path = ObjectPaths.path(for: object) else { return false }
        return path.contains(local, using: .winding)
    }

    // MARK: Hit test / helpers

    /// Whether `p` (canvas pixels) is inside the current selection region.
    func selectionContains(_ p: CGPoint) -> Bool {
        guard let region = selection.region else { return false }
        guard region.bounds.insetBy(dx: -1, dy: -1).contains(p) else { return false }
        if let path = region.makePath() {
            return path.contains(p, using: region.usesEvenOdd ? .evenOdd : .winding,
                                 transform: .identity)
        }
        if case .mask(let id, _) = region, let mask = surfaces.image(id),
           let buffer = MaskOps.readGray(mask, width: scene.canvas.pixelSize.width,
                                         height: scene.canvas.pixelSize.height) {
            let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
            let w = scene.canvas.pixelSize.width, h = scene.canvas.pixelSize.height
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            return buffer[y * w + x] > 127
        }
        return false
    }

    private var activeRasterSurface: (index: Int, id: SurfaceID, image: CGImage)? {
        guard let index = scene.activeLayerIndex, scene.layers[index].isEditable,
              case .raster(let id) = scene.layers[index].content,
              let image = surfaces.image(id) else { return nil }
        return (index, id, image)
    }

    private func transformedBounds(_ floating: FloatingPixels) -> CGRect {
        let r = floating.sourceRect
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        return CGRect(containing: corners.map { $0.applying(floating.transform) })
    }

    /// The composite within the region, cropped to its bounds — for copy.
    private func selectionImage() -> CGImage? {
        guard let region = selection.region,
              let composite = RasterOps.render(scene, surfaces: surfaces) else { return nil }
        let bounds = region.bounds.integral.intersection(scene.canvas.pageRect)
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        return liftPixels(from: composite, region: region, bounds: bounds)
    }

    /// Crop the pixels of `source` inside `region` into a `bounds`-sized tile.
    private func liftPixels(from source: CGImage, region: SelectionShape,
                            bounds: CGRect) -> CGImage? {
        let w = Int(bounds.width), h = Int(bounds.height)
        guard let ctx = PixelFormat.makeContext(width: w, height: h,
                                                colorSpace: scene.canvas.cgColorSpace) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)                       // y-down tile
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)   // bounds.origin → (0,0)
        MaskOps.clip(region, in: ctx, canvas: scene.canvas, surfaces: surfaces)
        ctx.setBlendMode(.copy)
        ctx.drawImageYDown(source, in: scene.canvas.pageRect)
        return ctx.makeImage()
    }

    /// A copy of `source` with the region cleared to alpha 0 (never white, T15).
    private func clearRegion(in source: CGImage, region: SelectionShape) -> CGImage? {
        let size = scene.canvas.pixelSize
        guard let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: scene.canvas.cgColorSpace) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.copy)
        ctx.drawImageYDown(source, in: size.rect)
        ctx.saveGState()
        MaskOps.clip(region, in: ctx, canvas: scene.canvas, surfaces: surfaces)
        ctx.setBlendMode(.clear)
        ctx.fill(size.rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// A copy of `source` with `color` painted inside the region.
    private func paintRegion(_ color: RGBAColor, region: SelectionShape,
                             onto source: CGImage) -> CGImage? {
        let size = scene.canvas.pixelSize
        guard let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: scene.canvas.cgColorSpace) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.copy)
        ctx.drawImageYDown(source, in: size.rect)
        ctx.saveGState()
        MaskOps.clip(region, in: ctx, canvas: scene.canvas, surfaces: surfaces)
        ctx.setBlendMode(.normal)
        ctx.setFillColor(color.cgColor)
        ctx.fill(size.rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// The dropped surface: cleared source with the float composited under its
    /// transform — the SAME draw the overlay previews, so screen == drop result.
    private func compositeFloat(_ floatImage: CGImage, transform: CGAffineTransform,
                                sourceRect: CGRect, onto source: CGImage) -> CGImage? {
        let size = scene.canvas.pixelSize
        guard let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: scene.canvas.cgColorSpace) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.copy)
        ctx.drawImageYDown(source, in: size.rect)
        ctx.setBlendMode(.normal)
        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.drawImageYDown(floatImage, in: sourceRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// How the redact tool obscures its region.
enum RedactStyle: Sendable { case blur, pixelate }

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
