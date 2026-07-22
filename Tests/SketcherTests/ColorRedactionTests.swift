import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

// MARK: - Helpers

private func whiteCanvas(_ side: Int = 200) -> Scene {
    Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: side, height: side),
                             pixelsPerPoint: 1, background: .light))
}

private func blackRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> DrawObject {
    var style = ObjectStyle(strokeColor: nil)
    style.fill = .solid(RGBAColor(r: 0, g: 0, b: 0))
    return DrawObject(kind: .rectangle(rect: CGRect(x: x, y: y, width: w, height: h),
                                       cornerRadius: 0), style: style)
}

/// Straight-alpha RGBA readback of a rendered scene.
private func renderRGBA(_ scene: Scene, _ surfaces: SurfaceStore) -> (px: [UInt8], w: Int)? {
    guard let image = ExportService.renderFullResolution(scene, surfaces: surfaces) else {
        return nil
    }
    let w = image.width, h = image.height
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (buffer, w)
}

private func nearBlackCount(_ px: [UInt8], w: Int, in region: CGRect) -> Int {
    var count = 0
    for y in Int(region.minY)..<Int(region.maxY) {
        for x in Int(region.minX)..<Int(region.maxX) {
            let i = (y * w + x) * 4
            if px[i] < 40, px[i + 1] < 40, px[i + 2] < 40, px[i + 3] > 200 { count += 1 }
        }
    }
    return count
}

private func imageSurface(_ scene: Scene) -> SurfaceID? {
    for object in scene.allObjects {
        if case .image(let payload) = object.kind { return payload.surface }
    }
    return nil
}

private func hasKind(_ scene: Scene, _ match: (ObjectKind) -> Bool) -> Bool {
    scene.allObjects.contains { match($0.kind) }
}

// MARK: - Redaction

@Suite("M4 Redaction")
@MainActor
struct RedactionTests {

    /// Drive the redact tool over a region.
    private func redact(_ viewModel: EditorViewModel, from: CGPoint, to: CGPoint,
                        style: RedactStyle = .blur) {
        viewModel.tool = .redact
        viewModel.redactStyle = style
        viewModel.pointerDown(at: from, tolerance: 6, modifiers: [])
        viewModel.pointerDragged(to: to)
        viewModel.pointerUp(at: to)
    }

    @Test("Redaction obliterates the covered pixels")
    func destructivePixels() {
        var scene = whiteCanvas()
        scene.addObject(blackRect(70, 70, 30, 30))
        let viewModel = EditorViewModel(scene: scene)

        let region = CGRect(x: 40, y: 40, width: 120, height: 120)
        guard let before = renderRGBA(viewModel.scene, viewModel.surfaces) else {
            Issue.record("render failed"); return
        }
        let blackBefore = nearBlackCount(before.px, w: before.w, in: region)
        #expect(blackBefore > 700)   // a 30×30 solid black square

        redact(viewModel, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160))

        guard let after = renderRGBA(viewModel.scene, viewModel.surfaces) else {
            Issue.record("render failed"); return
        }
        let blackAfter = nearBlackCount(after.px, w: after.w, in: region)
        // Blur spreads the black into grey — the sharp content is gone.
        #expect(blackAfter < blackBefore / 3)
    }

    @Test("Redaction destroys covered geometry — nothing recoverable in the file")
    func destructiveFile() throws {
        var scene = whiteCanvas()
        scene.addObject(blackRect(70, 70, 30, 30))
        let viewModel = EditorViewModel(scene: scene)

        redact(viewModel, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160))

        // The rectangle is gone from the scene, replaced by an opaque image patch.
        #expect(!hasKind(viewModel.scene) { if case .rectangle = $0 { return true }; return false })
        #expect(hasKind(viewModel.scene) { if case .image = $0 { return true }; return false })

        // And gone from the saved bytes (invariant 9): no rectangle geometry left.
        let data = try SceneCodec.encode(viewModel.scene)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("rectangle"))
    }

    @Test("A partially covered object is clipped, not deleted")
    func partialClip() {
        var scene = whiteCanvas()
        scene.addObject(blackRect(90, 90, 40, 40))   // spans out past the region
        let viewModel = EditorViewModel(scene: scene)

        redact(viewModel, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 100, y: 100))

        let rect = viewModel.scene.allObjects.first {
            if case .rectangle = $0.kind { return true }; return false
        }
        #expect(rect != nil)                                   // survived
        #expect(rect?.erasedGeometry?.isEmpty == false)        // but clipped
    }

    @Test("Redaction is one undo entry and survives undo → redo")
    func survivesUndoRedo() {
        var scene = whiteCanvas()
        scene.addObject(blackRect(70, 70, 30, 30))
        let viewModel = EditorViewModel(scene: scene)

        let entriesBefore = viewModel.history.undoStack.count
        redact(viewModel, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160))
        #expect(viewModel.history.undoStack.count == entriesBefore + 1)

        guard let surface = imageSurface(viewModel.scene) else {
            Issue.record("no patch surface"); return
        }
        #expect(viewModel.surfaces.image(surface) != nil)

        viewModel.undo()
        #expect(hasKind(viewModel.scene) { if case .rectangle = $0 { return true }; return false })
        #expect(!hasKind(viewModel.scene) { if case .image = $0 { return true }; return false })

        viewModel.redo()
        // The patch is back AND its pixels were NOT pruned during undo — the
        // whole point of keeping history-referenced surfaces alive.
        guard let restored = imageSurface(viewModel.scene) else {
            Issue.record("patch not restored"); return
        }
        #expect(viewModel.surfaces.image(restored) != nil)
    }

    @Test("Pixelate redaction also removes the covered geometry")
    func pixelateDestroys() {
        var scene = whiteCanvas()
        scene.addObject(blackRect(70, 70, 30, 30))
        let viewModel = EditorViewModel(scene: scene)
        redact(viewModel, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160),
               style: .pixelate)
        #expect(!hasKind(viewModel.scene) { if case .rectangle = $0 { return true }; return false })
    }
}

// MARK: - Color

@Suite("M4 Color")
@MainActor
struct ColorTests {

    @Test("Swap exchanges primary and secondary; reset restores black/white")
    func swapAndReset() {
        let viewModel = EditorViewModel(scene: whiteCanvas())
        viewModel.primaryColor = .red
        viewModel.secondaryColor = .blue
        viewModel.swapColors()
        #expect(viewModel.primaryColor == .blue)
        #expect(viewModel.secondaryColor == .red)

        viewModel.resetColors()
        #expect(viewModel.primaryColor == .black)
        #expect(viewModel.secondaryColor == .white)
    }

    @Test("Recents de-duplicate, keep newest first, and cap at 8")
    func recents() {
        let viewModel = EditorViewModel(scene: whiteCanvas())
        let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple,
                                    .black, .white, RGBAColor(r: 0.5, g: 0.5, b: 0.5)]
        for color in palette { viewModel.rememberColor(color) }
        #expect(viewModel.recentColors.count == 8)             // capped
        #expect(viewModel.recentColors.first == palette.last)  // newest first

        viewModel.rememberColor(.red)                          // re-use an old one
        #expect(viewModel.recentColors.first == .red)
        #expect(viewModel.recentColors.filter { $0 == .red }.count == 1)   // de-duped
    }

    @Test("Choosing a swatch recolors the selection as one undo entry")
    func chooseRecolorsSelection() {
        var scene = whiteCanvas()
        scene.addObject(blackRect(10, 10, 40, 40))
        let viewModel = EditorViewModel(scene: scene)
        let id = viewModel.scene.allObjects[0].id
        viewModel.selection.select(id)

        let before = viewModel.history.undoStack.count
        viewModel.chooseColor(.red)
        #expect(viewModel.scene.object(with: id)?.style.strokeColor == .red)
        #expect(viewModel.history.undoStack.count == before + 1)
    }

    @Test("The eyedropper samples the composited canvas")
    func eyedropperSamples() {
        var scene = whiteCanvas()
        var style = ObjectStyle(strokeColor: nil)
        style.fill = .solid(.red)
        scene.addObject(DrawObject(kind: .rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                    cornerRadius: 0), style: style))
        let viewModel = EditorViewModel(scene: scene)

        guard let sampled = viewModel.sampleCanvas(at: CGPoint(x: 50, y: 50)) else {
            Issue.record("sample failed"); return
        }
        #expect(sampled.r > 0.8)
        #expect(sampled.g < 0.4)
        #expect(sampled.b < 0.4)

        // A point on the white background reads back near white.
        guard let white = viewModel.sampleCanvas(at: CGPoint(x: 150, y: 150)) else {
            Issue.record("sample failed"); return
        }
        #expect(white.r > 0.9 && white.g > 0.9 && white.b > 0.9)
    }
}

// MARK: - Style inspector

@Suite("M4 Style")
@MainActor
struct StyleInspectorTests {

    private func selectedRect() -> (EditorViewModel, UUID) {
        var scene = whiteCanvas()
        var style = ObjectStyle(strokeColor: .black, strokeWidthPx: 4)
        scene.addObject(DrawObject(kind: .rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 40),
                                                    cornerRadius: 0), style: style))
        let viewModel = EditorViewModel(scene: scene)
        let id = viewModel.scene.allObjects[0].id
        viewModel.selection.select(id)
        _ = style
        return (viewModel, id)
    }

    @Test("A stroke-width drag coalesces into one undo entry")
    func strokeWidthCoalesces() {
        let (viewModel, id) = selectedRect()
        let before = viewModel.history.undoStack.count
        viewModel.beginStyleEdit()
        for w in stride(from: 2.0, through: 20.0, by: 2.0) {
            viewModel.setStrokeWidthPx(CGFloat(w))
        }
        viewModel.endStyleEdit("Stroke Width")
        #expect(viewModel.history.undoStack.count == before + 1)
        #expect(viewModel.scene.object(with: id)?.style.strokeWidthPx == 20)
    }

    @Test("Fill toggle and color apply to the selection")
    func fillEditing() {
        let (viewModel, id) = selectedRect()
        #expect(viewModel.scene.object(with: id)?.style.fill.isVisible == false)
        viewModel.setFillEnabled(true)
        #expect(viewModel.scene.object(with: id)?.style.fill.isVisible == true)
        viewModel.setFillColor(.red)
        #expect(viewModel.scene.object(with: id)?.style.fill.color == .red)
    }

    @Test("Corner radius edits the selected rectangle")
    func cornerRadius() {
        let (viewModel, id) = selectedRect()
        #expect(viewModel.inspectorHasRect)
        viewModel.setCornerRadiusPx(12)
        if case .rectangle(_, let radius) = viewModel.scene.object(with: id)?.kind {
            #expect(radius == 12)
        } else {
            Issue.record("not a rectangle")
        }
    }

    @Test("With no selection, style edits change the armed-tool defaults")
    func editsToolDefaults() {
        let viewModel = EditorViewModel(scene: whiteCanvas())
        viewModel.selection.clear()
        let px = viewModel.scene.canvas.px(fromPoints: 10)
        viewModel.setStrokeWidthPx(px)
        #expect(viewModel.style.strokeWidthPx == px)
        #expect(viewModel.brush.sizePx == px)
        // No object exists to change, and no undo entry is pushed.
        #expect(viewModel.history.undoStack.isEmpty)
    }

    @Test("inspectorStyle reflects the topmost selected object")
    func inspectorReflectsSelection() {
        let (viewModel, _) = selectedRect()
        #expect(viewModel.inspectorStyle.strokeWidthPx == 4)
    }
}
