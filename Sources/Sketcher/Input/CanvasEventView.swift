import AppKit
import SwiftUI

/// ALL input comes through here — pointer, keys, scroll, magnify, pressure,
/// tilt, and modifiers, every one read off a single `NSEvent`.
///
/// This is an AppKit view rather than a SwiftUI gesture because SwiftUI's
/// `DragGesture` exposes no pressure, no tilt, no scroll wheel, and no
/// per-event modifier flags, and it coalesces samples. The pressure brush is
/// simply unimplementable on it.
///
/// The view draws nothing: it is a transparent overlay above the rendering
/// canvas. Rendering can therefore be swapped from SwiftUI `Canvas` to a
/// `CALayer`-backed view without touching input.
@MainActor
final class CanvasEventView: NSView {
    private let viewModel: EditorViewModel

    /// Space-drag pans from any tool. Tracked here because it is a transient
    /// input mode, not document or tool state.
    private var spaceHeld = false {
        didSet {
            guard spaceHeld != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Where the current drag started, in view points — used for slop and for
    /// pan deltas.
    private var dragOrigin: CGPoint?
    /// True once a drag has travelled past the slop threshold.
    private var dragMoved = false
    private var panLast: CGPoint?

    /// A click must travel this far (view points) before it counts as a drag.
    /// Without it, a jittery click becomes a 1px move and a junk undo entry.
    private static let dragSlop: CGFloat = 2

    // MARK: - Text editing (M5)

    /// The `NSTextView` input sink, present only while a text object is being
    /// edited. It is a child of this view, so clicks INSIDE it position the
    /// caret while clicks OUTSIDE reach `mouseDown` and commit by resigning it.
    private var textSink: TextSinkView?
    /// Set while tearing the sink down so its resign does not re-commit.
    private var suppressTextCommit = false
    /// The attribute signature last pushed into the sink, so reconfiguring it
    /// (which can disrupt an in-flight IME composition) happens only on change.
    private var sinkSignature: String?

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Top-left origin, y-down — matching the canvas coordinate space, so the
    /// only conversion left for `CanvasTransform` is scale and offset.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Draw the first click instead of just focusing the window, so a stroke
    /// started on an inactive window is not silently swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: - Coordinate conversion (the ONE boundary)

    private func canvasPoint(_ event: PointerEvent) -> CGPoint {
        viewModel.transform.toCanvas(event.location)
    }

    private var hitTolerance: CGFloat {
        viewModel.transform.canvasTolerance(viewPoints: 6)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let e = PointerEvent(nsEvent: event, in: self)
        dragOrigin = e.location
        dragMoved = false

        if spaceHeld || viewModel.tool == .hand {
            panLast = e.location
            return
        }

        // Zoom is a VIEWPORT concern, so it is handled here in view space
        // rather than being routed through the model's canvas coordinates.
        // Option-click zooms out, matching every editor.
        if viewModel.tool == .zoom {
            let factor: CGFloat = e.modifiers.contains(.option) ? 0.5 : 2
            viewModel.zoom(by: factor, about: e.location)
            return
        }

        viewModel.pointerDown(at: canvasPoint(e), tolerance: hitTolerance,
                              modifiers: e.modifiers)
    }

    override func mouseDragged(with event: NSEvent) {
        let e = PointerEvent(nsEvent: event, in: self)

        if panLast != nil {
            let last = panLast ?? e.location
            viewModel.pan(by: CGPoint(x: e.location.x - last.x, y: e.location.y - last.y))
            panLast = e.location
            return
        }

        // Slop gate: a click that jitters by a pixel must not become a move.
        if !dragMoved, let origin = dragOrigin {
            guard e.location.distance(to: origin) > Self.dragSlop else { return }
            dragMoved = true
        }
        viewModel.pointerDragged(to: canvasPoint(e), pressure: e.pressure,
                                 modifiers: e.modifiers)
    }

    override func mouseUp(with event: NSEvent) {
        let e = PointerEvent(nsEvent: event, in: self)
        defer {
            dragOrigin = nil
            dragMoved = false
            panLast = nil
        }
        if panLast != nil { return }
        viewModel.pointerUp(at: canvasPoint(e))
    }

    // MARK: - Scroll, zoom, pan

    override func scrollWheel(with event: NSEvent) {
        // Cmd+scroll zooms at the cursor; plain scroll pans. This is the macOS
        // convention across Preview, Sketch, and Figma.
        let location = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 3
            guard delta != 0 else { return }
            viewModel.zoom(by: 1 + delta * 0.005, about: location)
            return
        }

        // Line-based mice report tiny deltas; precise trackpads report points.
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }
        // Natural-scrolling users otherwise pan backwards.
        if event.isDirectionInvertedFromDevice {
            dx = -dx
            dy = -dy
        }
        viewModel.pan(by: CGPoint(x: dx, y: dy))
    }

    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        viewModel.zoom(by: 1 + event.magnification, about: location)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // While a text field owns the keyboard, the canvas must not intercept
        // tool letters — typing "Better" would otherwise swap tools six times.
        if isTextInputActive {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == KeyMap.spaceKeyCode {
            spaceHeld = true
            return
        }

        let shift = event.modifierFlags.contains(.shift)
        if let delta = KeyMap.nudge(for: event.keyCode, shift: shift) {
            viewModel.nudgeSelection(dx: delta.x, dy: delta.y)
            return
        }

        // Let the menu bar own every Command combination: it has the key
        // equivalents, the validation, and the discoverability.
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }

        guard let characters = event.charactersIgnoringModifiers,
              let character = characters.first else {
            super.keyDown(with: event)
            return
        }

        if KeyMap.isDeleteKey(character) {
            viewModel.deleteSelection()
            return
        }
        if KeyMap.isEscape(character) {
            viewModel.escape()
            return
        }
        if let step = KeyMap.isBracket(character) {
            viewModel.adjustBrushSize(step: step)
            return
        }

        // Color + redaction single-key actions, shift-aware. Handled before the
        // tool table because some share a letter with a tool (I, J).
        switch character.lowercased() {
        case "x": viewModel.swapColors(); return
        case "d": viewModel.resetColors(); return
        case "b":
            // Shift+B cycles the brush preset; either way arm the brush.
            if shift { viewModel.cycleBrushEngine() }
            viewModel.tool = .brush
            window?.invalidateCursorRects(for: self)
            return
        case "e":
            // Shift+E cycles the eraser mode; either way arm the eraser.
            if shift { viewModel.cycleEraserMode() }
            viewModel.tool = .eraser
            window?.invalidateCursorRects(for: self)
            return
        case "i":
            if shift {
                ColorCommands.pickScreenColor(viewModel)
            } else {
                viewModel.tool = .eyedropper
                window?.invalidateCursorRects(for: self)
            }
            return
        case "j":
            viewModel.tool = .redact
            viewModel.redactStyle = shift ? .pixelate : .blur
            window?.invalidateCursorRects(for: self)
            return
        default:
            break
        }

        if let tool = KeyMap.tool(for: character) {
            viewModel.tool = tool
            window?.invalidateCursorRects(for: self)
            return
        }

        // Unhandled: pass along rather than swallowing, or the key beeps.
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == KeyMap.spaceKeyCode {
            spaceHeld = false
            return
        }
        super.keyUp(with: event)
    }

    private var isTextInputActive: Bool {
        window?.firstResponder is NSText
    }

    // MARK: - Text editing overlay

    /// Reconcile the sink with the view model's editing state. Called from
    /// `CanvasEventLayer.updateNSView`, which SwiftUI re-runs whenever the
    /// editing id, scene, or viewport changes — exactly when the sink must
    /// appear, resize (auto-width growth, zoom), or tear down.
    func syncTextEditing() {
        guard viewModel.isEditingText,
              let object = viewModel.editingTextObject,
              case .text(let payload) = object.kind,
              window != nil else {
            teardownTextSink()
            return
        }

        let sink = ensureTextSink()
        let transform = viewModel.transform

        // The box in view points. `object.bounds` is the CoreText layout box for
        // both fixed and auto-width, so the sink tracks the visible text.
        sink.frame = transform.toView(object.bounds)

        // Reconfigure font/alignment/line-height only when they actually change,
        // so a keystroke (which round-trips through the payload) does not reset
        // the field editor mid-composition.
        let ink = object.style.strokeColor ?? .black
        let signature = attributeSignature(payload, scale: transform.scale, ink: ink)
        if signature != sinkSignature {
            configure(sink, payload: payload, scale: transform.scale, ink: ink)
            sinkSignature = signature
        }

        // Adopt an externally-changed string (an undo, say) without clobbering
        // an in-flight IME composition or the caret during normal typing.
        if !sink.hasMarkedText(), sink.string != payload.string {
            sink.string = payload.string
        }

        if window?.firstResponder !== sink {
            window?.makeFirstResponder(sink)
            let end = (sink.string as NSString).length
            sink.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    private func ensureTextSink() -> TextSinkView {
        if let sink = textSink { return sink }
        let sink = TextSinkView.make()
        sink.onEdit = { [weak self] string in self?.viewModel.updateEditingText(string) }
        sink.onCommit = { [weak self] in
            guard let self, !self.suppressTextCommit else { return }
            self.viewModel.commitTextEditing()
        }
        sink.onResign = { [weak self] in
            guard let self, !self.suppressTextCommit else { return }
            self.viewModel.commitTextEditing()
        }
        sink.onFont = { [weak self] font in
            guard let self else { return }
            let scale = self.viewModel.transform.scale
            self.viewModel.applyTextFont(
                name: font.fontName,
                sizePx: font.pointSize / max(scale, 0.0001),
                bold: font.hasTrait(.boldFontMask),
                italic: font.hasTrait(.italicFontMask))
        }
        addSubview(sink)
        textSink = sink
        sinkSignature = nil
        return sink
    }

    private func teardownTextSink() {
        guard let sink = textSink else { return }
        suppressTextCommit = true
        if window?.firstResponder === sink { window?.makeFirstResponder(self) }
        sink.removeFromSuperview()
        textSink = nil
        sinkSignature = nil
        suppressTextCommit = false
    }

    private func configure(_ sink: TextSinkView, payload: TextPayload,
                           scale: CGFloat, ink: RGBAColor) {
        let font = TextSinkView.font(for: payload, scale: scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = payload.alignment.nsAlignment
        paragraph.lineHeightMultiple = payload.lineHeightMultiple
        sink.font = font
        sink.alignment = payload.alignment.nsAlignment
        sink.defaultParagraphStyle = paragraph
        sink.insertionPointColor = ink.nsColor
        // Glyphs stay clear (CoreText draws them); only the caret is visible.
        sink.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.clear,
            .paragraphStyle: paragraph
        ]
        if payload.resize == .autoWidth {
            sink.textContainer?.widthTracksTextView = false
            sink.textContainer?.size = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        } else {
            sink.textContainer?.widthTracksTextView = true
        }
    }

    private func attributeSignature(_ payload: TextPayload, scale: CGFloat,
                                    ink: RGBAColor) -> String {
        "\(payload.fontName)|\(payload.fontSizePx)|\(payload.isBold)|\(payload.isItalic)|"
            + "\(payload.alignment)|\(payload.lineHeightMultiple)|\(payload.resize)|"
            + "\(scale)|\(ink)"
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    private var currentCursor: NSCursor {
        if spaceHeld { return .openHand }
        switch viewModel.tool {
        case .hand: return .openHand
        case .text: return .iBeam
        case .select: return .arrow
        case .zoom: return .crosshair
        case .brush, .eraser, .rectangle, .ellipse, .line, .arrow, .polygon,
             .redact, .eyedropper, .bucket, .marquee, .lasso, .wand, .crop:
            return .crosshair
        }
    }
}

/// SwiftUI bridge. The view model is passed by reference and never re-created,
/// so the AppKit view keeps its first responder status across SwiftUI updates.
struct CanvasEventLayer: NSViewRepresentable {
    let viewModel: EditorViewModel
    /// These are read in `CanvasView.body` purely so SwiftUI re-runs
    /// `updateNSView` when editing starts/stops, the scene changes, or the
    /// viewport moves — exactly when the text-editing child must appear, resize,
    /// or reposition. (`syncTextEditing` itself reads the live view model.)
    var editingTextID: UUID?
    var sceneRevision: UInt64
    var transform: CanvasTransform

    func makeNSView(context: Context) -> CanvasEventView {
        CanvasEventView(viewModel: viewModel)
    }

    func updateNSView(_ nsView: CanvasEventView, context: Context) {
        nsView.syncTextEditing()
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
