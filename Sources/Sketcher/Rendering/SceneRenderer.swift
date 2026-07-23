import CoreGraphics
import Foundation

/// The single draw routine for document content, shared by the on-screen canvas
/// (`GraphicsContext.withCGContext`), full-resolution export, and the committed
/// render cache.
///
/// The context must already be transformed so 1 unit == 1 canvas pixel,
/// top-left origin, y-down. Screen and export cannot diverge: same code.
///
/// Chrome — selection handles, marching ants, guides, grid, brush ring, the
/// transparency checkerboard — is NOT drawn here. It belongs to the view
/// overlay and must never appear in an export.
enum SceneRenderer {
    /// Passes: canvas background -> layers bottom-to-top -> floating pixels.
    ///
    /// - Parameters:
    ///   - excluding: objects being dragged live; the caller draws them itself
    ///     each frame so the committed cache does not rebuild per frame.
    ///   - clipToPage: contained mode clips to the page rect. Export always
    ///     clips, since the page rect IS the export boundary in both modes.
    static func draw(_ scene: Scene,
                     surfaces: SurfaceStore,
                     into ctx: CGContext,
                     excluding: Set<UUID> = [],
                     clipToPage: Bool = true) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let page = scene.canvas.pageRect
        if clipToPage {
            ctx.clip(to: page)
        }

        drawBackground(scene.canvas, in: page, into: ctx)

        for layer in scene.layers where layer.isVisible {
            draw(layer, scene: scene, surfaces: surfaces,
                 into: ctx, excluding: excluding)
        }
    }

    /// `.transparent` deliberately draws NOTHING — the checkerboard is view
    /// chrome, and baking it into the context would bake it into the PNG.
    static func drawBackground(_ canvas: CanvasSpec, in rect: CGRect,
                               into ctx: CGContext) {
        guard let color = canvas.background.solidColor else { return }
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    private static func draw(_ layer: Layer, scene: Scene, surfaces: SurfaceStore,
                             into ctx: CGContext, excluding: Set<UUID>) {
        switch layer.content {
        case .raster(let id):
            guard let image = surfaces.image(id) else { return }
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            ctx.setBlendMode(layer.blend)
            ctx.drawImageYDown(image, in: scene.canvas.pageRect)
            ctx.restoreGState()

        case .vector(let objects):
            let visible = objects.filter { !$0.isHidden && !excluding.contains($0.id) }
            guard !visible.isEmpty else { return }

            if layer.isTransparent {
                // Fast path: no isolation needed, so no offscreen allocation.
                for object in visible { draw(object, surfaces: surfaces, into: ctx) }
                return
            }

            // Isolated layer: render to an offscreen and composite ONCE, so two
            // overlapping strokes on a 50%-opacity layer do not double-darken.
            let size = scene.canvas.pixelSize
            guard let offscreen = PixelFormat.makeContext(
                width: size.width, height: size.height,
                colorSpace: scene.canvas.cgColorSpace) else {
                // Allocation failed (canvas too large): degrade to the direct
                // path rather than dropping the layer entirely.
                ctx.saveGState()
                ctx.setAlpha(layer.opacity)
                ctx.setBlendMode(layer.blend)
                for object in visible { draw(object, surfaces: surfaces, into: ctx) }
                ctx.restoreGState()
                return
            }
            offscreen.translateBy(x: 0, y: CGFloat(size.height))
            offscreen.scaleBy(x: 1, y: -1)   // y-down, matching the renderer contract
            for object in visible { draw(object, surfaces: surfaces, into: offscreen) }

            guard let image = offscreen.makeImage() else { return }
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            ctx.setBlendMode(layer.blend)
            ctx.drawImageYDown(image, in: scene.canvas.pageRect)
            ctx.restoreGState()
        }
    }

    // MARK: - Objects

    static func draw(_ object: DrawObject, surfaces: SurfaceStore, into ctx: CGContext) {
        guard !object.isHidden else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setShouldAntialias(object.style.antialias)
        ctx.setAlpha(object.style.opacity)
        ctx.setBlendMode(object.style.blend)
        if let shadow = object.style.shadow {
            ctx.setShadow(offset: shadow.offset,
                          blur: shadow.blurRadiusPx,
                          color: shadow.color.cgColor)
        }

        if object.isRotatable, object.rotation != 0 {
            let c = object.rotationCenter
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: object.rotation)
            ctx.translateBy(x: -c.x, y: -c.y)
        }

        // Partial erase: clip AWAY the erased region. Each subpath is punched as
        // its OWN hole — (huge rect + one subpath), even-odd — and the sequential
        // clips intersect. Combining all subpaths into one even-odd path would
        // un-erase wherever two eraser strokes overlap (winding 2 reads as
        // "outside the hole"); clipping them one at a time keeps the overlap
        // erased. CGContext has no direct "subtract from clip".
        if let erased = object.erasedGeometry, !erased.isEmpty {
            for sub in erased.subpaths where sub.count >= 3 {
                let hole = CGMutablePath()
                hole.addRect(CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6))
                hole.addLines(between: sub)
                hole.closeSubpath()
                ctx.addPath(hole)
                ctx.clip(using: .evenOdd)
            }
        }

        drawUnrotated(object, surfaces: surfaces, into: ctx)
    }

    private static func drawUnrotated(_ object: DrawObject, surfaces: SurfaceStore,
                                      into ctx: CGContext) {
        let style = object.style

        switch object.kind {
        case .rectangle, .ellipse, .polygon, .line, .polyline:
            guard let path = ObjectPaths.path(for: object) else { return }
            fillAndStroke(path, style: style, closed: isClosed(object.kind), in: ctx)

        case .arrow(let payload):
            drawArrow(payload, style: style, in: ctx)

        case .stroke(let payload):
            let color = (style.strokeColor ?? .black).cgColor
            StrokeGeometry.fill(BrushEngine.outline(for: payload), color: color,
                                blendMode: payload.brush.blendMode,
                                antialias: style.antialias, in: ctx)

        case .text(let payload):
            TextMetrics.draw(payload, color: (style.strokeColor ?? .black).cgColor, in: ctx)

        case .image(let payload):
            guard let image = surfaces.image(payload.surface) else { return }
            ctx.interpolationQuality = payload.interpolation
            ctx.drawImageYDown(image, in: payload.rect)

        case .filter:
            // Filters are resolved by FilterPatchCache in a separate pass (M4);
            // there is nothing to draw inline.
            break

        case .unknown:
            // Forward compat: renders nothing, but round-trips on save.
            break
        }
    }

    private static func isClosed(_ kind: ObjectKind) -> Bool {
        switch kind {
        case .rectangle, .ellipse, .polygon: return true
        case .polyline(_, let closed): return closed
        default: return false
        }
    }

    private static func fillAndStroke(_ path: CGPath, style: ObjectStyle,
                                      closed: Bool, in ctx: CGContext) {
        if closed, case .solid(let fill) = style.fill, fill.a > 0 {
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        guard style.hasVisibleStroke, let stroke = style.strokeColor else { return }
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(style.strokeWidthPx)
        ctx.setLineCap(style.lineCap)
        ctx.setLineJoin(style.lineJoin)
        if let lengths = style.dash.lengths(strokeWidth: style.strokeWidthPx) {
            ctx.setLineDash(phase: 0, lengths: lengths)
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func drawArrow(_ payload: ArrowPayload, style: ObjectStyle,
                                  in ctx: CGContext) {
        guard let color = style.strokeColor else { return }

        // Head geometry is computed from the far end inward, so the shaft can be
        // pulled back and the filled head owns the tip.
        let endGeom = ArrowGeometry(start: payload.start, end: payload.end,
                                    strokeWidthPx: style.strokeWidthPx,
                                    head: payload.endHead)
        let startGeom = ArrowGeometry(start: payload.end, end: payload.start,
                                      strokeWidthPx: style.strokeWidthPx,
                                      head: payload.startHead)

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(style.strokeWidthPx)
        ctx.setLineCap(style.lineCap)
        ctx.setLineJoin(style.lineJoin)

        if let control = payload.control {
            // A curved arrow keeps its full shaft; trimming a quad curve to the
            // head is not worth the arc-length solve at this stroke width.
            ctx.addPath(ObjectPaths.quadPath(from: payload.start,
                                             control: control, to: payload.end))
            ctx.strokePath()
        } else {
            ctx.move(to: startGeom.shaftEnd)
            ctx.addLine(to: endGeom.shaftEnd)
            ctx.strokePath()
        }

        if let head = endGeom.headPath { ctx.addPath(head); ctx.fillPath() }
        if let head = startGeom.headPath { ctx.addPath(head); ctx.fillPath() }
    }
}

extension CGContext {
    /// `CGContext.draw(_:in:)` assumes y-up; in our y-down contexts images
    /// would render mirrored. This flips locally around the target rect.
    ///
    /// One of the isolated y-flip sites. Nothing else may flip.
    func drawImageYDown(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: 0, y: rect.minY + rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: rect)
        restoreGState()
    }
}
