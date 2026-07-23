import CoreGraphics
import Foundation

/// Pixel operations over immutable surfaces.
///
/// Every function returns a NEW `CGImage` that owns its pixels — surfaces are
/// immutable (invariant 6), so a mutation never writes an existing buffer in
/// place. That is what lets a history entry hold a surface ID and trust the
/// pixels behind it never change.
///
/// `nonisolated` and free-function-shaped from the first line (invariant 11):
/// rasterize, flatten, and erase all block the UI otherwise, and they are called
/// off-main by the export and cache paths.
///
/// Rendering routes through the ONE `SceneRenderer` (invariant 2): rasterize and
/// flatten build a throwaway `Scene` and draw it exactly as the screen and
/// export do, so a rasterized layer cannot drift from its on-screen look.
enum RasterOps {
    /// Render a scene's content into a fresh canvas-sized surface. y-down to
    /// match the renderer contract; the background is whatever the temp scene
    /// carries (callers pass transparent when baking layers).
    static func render(_ scene: Scene, surfaces: SurfaceStore) -> CGImage? {
        let size = scene.canvas.pixelSize
        guard size.isValid,
              let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: scene.canvas.cgColorSpace)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        SceneRenderer.draw(scene, surfaces: surfaces, into: ctx, clipToPage: false)
        return ctx.makeImage()
    }

    /// Bake a single layer's CONTENT to pixels, dropping its opacity and blend so
    /// the layer keeps those and only its content becomes a surface (Rasterize
    /// Layer). Off-page content is clipped, since a surface is exactly page-sized.
    static func rasterizeContent(of layer: Layer, in scene: Scene,
                                 surfaces: SurfaceStore) -> CGImage? {
        var isolated = layer
        isolated.opacity = 1
        isolated.blend = .normal
        isolated.isVisible = true
        var temp = scene
        temp.layers = [isolated]
        temp.canvas.background = .transparent
        return render(temp, surfaces: surfaces)
    }

    /// Composite the given layers (honoring each one's visibility, opacity, and
    /// blend) onto transparency — Merge Down and Flatten. The canvas background
    /// is a canvas property, not a layer, so it is deliberately not baked in.
    static func flatten(_ layers: [Layer], in scene: Scene,
                        surfaces: SurfaceStore) -> CGImage? {
        var temp = scene
        temp.layers = layers
        temp.canvas.background = .transparent
        return render(temp, surfaces: surfaces)
    }

    /// A fresh fully-transparent surface at canvas size — a new empty raster layer.
    static func blank(_ canvas: CanvasSpec) -> CGImage? {
        let size = canvas.pixelSize
        guard let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: canvas.cgColorSpace)
        else { return nil }
        return ctx.makeImage()
    }

    /// Clear `polygon` (canvas pixels, y-down) out of `image`, returning a new
    /// surface. The pixel eraser: `.clear` zeroes alpha, so erasing on a
    /// transparent canvas yields alpha 0 — never white, the classic eraser bug.
    static func erase(_ image: CGImage, polygon: [CGPoint],
                      canvas: CanvasSpec, antialias: Bool = true) -> CGImage? {
        let size = canvas.pixelSize
        guard polygon.count >= 3,
              let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: canvas.cgColorSpace)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.copy)
        ctx.drawImageYDown(image, in: size.rect)

        ctx.setShouldAntialias(antialias)
        ctx.setBlendMode(.clear)
        let path = CGMutablePath()
        path.addLines(between: polygon)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// Copy a sub-rect into a FRESH bitmap, materializing the pixels.
    ///
    /// CRITICAL (invariant 6, the T1 project-killer): `CGImage.cropping(to:)`
    /// does NOT copy — the SDK header states it "retains a reference to the
    /// original image" — so a cropped tile would secretly pin the whole canvas
    /// and 50 history patches would reach gigabytes. This draws into its own
    /// context so `SurfaceStore.totalBytes` counts the tile, not the canvas.
    static func materialize(_ image: CGImage, cropTo rect: CGRect,
                            canvas: CanvasSpec) -> CGImage? {
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        guard w > 0, h > 0,
              let ctx = PixelFormat.makeContext(width: w, height: h,
                                                colorSpace: canvas.cgColorSpace)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)   // y-down tile
        ctx.setBlendMode(.copy)
        // Draw the whole source shifted so the crop's top-left lands at (0,0);
        // the tile-sized context clips away everything else.
        let dest = CGRect(x: -rect.minX, y: -rect.minY,
                          width: CGFloat(canvas.pixelSize.width),
                          height: CGFloat(canvas.pixelSize.height))
        ctx.drawImageYDown(image, in: dest)
        return ctx.makeImage()
    }

    /// Paint `tile` over `base` at `rect`, replacing that region exactly, and
    /// return the new full surface. `.copy` means the tile's own alpha wins, so
    /// restoring a previously-transparent region really clears it. Used to apply
    /// a `RasterPatch` on undo/redo.
    static func compositeTile(_ tile: CGImage, into base: CGImage, at rect: CGRect,
                              canvas: CanvasSpec) -> CGImage? {
        let size = canvas.pixelSize
        guard let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: canvas.cgColorSpace)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.copy)
        ctx.drawImageYDown(base, in: size.rect)
        ctx.drawImageYDown(tile, in: rect)
        return ctx.makeImage()
    }
}
