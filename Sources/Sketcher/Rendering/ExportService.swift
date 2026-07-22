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

    /// PNG bytes with DPI stamped so paste targets show the image at its
    /// natural size rather than 2x blown up on a Retina source.
    static func pngData(_ image: CGImage, pixelsPerPoint: CGFloat) -> Data? {
        ImageExporter.data(image, format: .png, pixelsPerPoint: pixelsPerPoint)
    }
}
