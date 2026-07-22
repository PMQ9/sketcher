import CoreGraphics
import Foundation

/// Full-resolution rendering to a bitmap.
///
/// Goes through `SceneRenderer` exactly like the screen does — that shared path
/// is what makes WYSIWYG structural rather than aspirational. The page rect is
/// the export boundary in BOTH canvas modes, so an export is always exactly
/// `canvas.pixelSize`.
enum ExportService {

    /// Render the scene at exact canvas pixel dimensions.
    ///
    /// Returns nil rather than trapping when the context cannot be allocated —
    /// a large canvas can legitimately fail, and that must be a handled path.
    static func renderFullResolution(_ scene: Scene,
                                     surfaces: SurfaceStore,
                                     background: CanvasBackground? = nil) -> CGImage? {
        let size = scene.canvas.pixelSize
        guard size.isValid else { return nil }
        guard let ctx = PixelFormat.makeContext(width: size.width,
                                                height: size.height,
                                                colorSpace: scene.canvas.cgColorSpace) else {
            return nil
        }

        // Y-flip site #2: the renderer's contract is y-down, CoreGraphics is
        // y-up. One flip here, applied to the whole export.
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        var exported = scene
        if let background { exported.canvas.background = background }

        // Always clip to the page: it IS the export boundary, in contained and
        // infinite mode alike.
        SceneRenderer.draw(exported, surfaces: surfaces, into: ctx, clipToPage: true)

        return ctx.makeImage()
    }

    /// Render only `rect` of the canvas — used by Export Selection and by
    /// region copy (M7).
    static func renderRegion(_ scene: Scene, surfaces: SurfaceStore,
                             rect: CGRect) -> CGImage? {
        let clamped = rect.integral.intersection(scene.canvas.pageRect)
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        guard let ctx = PixelFormat.makeContext(width: Int(clamped.width),
                                                height: Int(clamped.height),
                                                colorSpace: scene.canvas.cgColorSpace) else {
            return nil
        }
        ctx.translateBy(x: 0, y: clamped.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        // Shift the world so the region's origin lands at 0,0.
        ctx.translateBy(x: -clamped.minX, y: -clamped.minY)

        SceneRenderer.draw(scene, surfaces: surfaces, into: ctx, clipToPage: true)
        return ctx.makeImage()
    }

    /// Render just `objects` onto a transparent canvas sized to their union
    /// bounds. The clipboard image and selection drag-out use this — only the
    /// selected objects, never whatever they happen to overlap.
    static func renderObjects(_ objects: [DrawObject], surfaces: SurfaceStore,
                              pixelsPerPoint: CGFloat, colorSpaceName: String) -> CGImage? {
        let bounds = objects.reduce(CGRect.null) { $0.unionIgnoringNull($1.renderBounds) }
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        let size = PixelSize(width: Int(bounds.width.rounded(.up)),
                             height: Int(bounds.height.rounded(.up)))
        guard size.isValid else { return nil }

        var canvas = CanvasSpec(pixelSize: size, pixelsPerPoint: pixelsPerPoint,
                                background: .transparent, mode: .contained)
        canvas.colorSpaceName = colorSpaceName
        var scene = Scene(canvas: canvas)
        // Shift the objects so their bounding box sits at the origin.
        scene.layers[0].objects = objects.map {
            var copy = $0
            copy.translate(by: CGPoint(x: -bounds.minX, y: -bounds.minY))
            return copy
        }
        return renderFullResolution(scene, surfaces: surfaces)
    }

    /// PNG bytes with DPI stamped so paste targets show the image at its
    /// natural size rather than 2x blown up on a Retina source.
    static func pngData(_ image: CGImage, pixelsPerPoint: CGFloat) -> Data? {
        ImageExporter.data(image, format: .png, pixelsPerPoint: pixelsPerPoint)
    }
}
