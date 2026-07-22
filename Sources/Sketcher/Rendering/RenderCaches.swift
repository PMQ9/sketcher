import CoreGraphics
import Foundation

/// The committed/live render split.
///
/// Measured on this machine: a full-scene render costs ~0.00065 ms per stroke
/// sample, so the 8.3 ms frame budget breaks at roughly 12,700 points — a few
/// minutes of sketching. A cached blit costs 0.34 ms regardless of complexity.
/// See PROGRESS.md §7. This class is therefore load-bearing, not an
/// optimization.
///
/// Strategy:
/// - At `scale <= 1.0`, blit a cached full-canvas image. It is at native canvas
///   resolution, so downscaling it introduces no softness.
/// - Above 1.0, bypass the cache and render live clipped to the visible rect —
///   bounded, because the visible canvas area shrinks as scale grows (at 400% a
///   1600×1000 pt window covers only ~400×250 canvas pixels).
/// - Objects being dragged are excluded from the cache and drawn live, so an
///   edit to an existing object does not rebuild the cache every frame.
final class RenderCaches {
    /// Above this zoom the live path is cheaper than a full-canvas rebuild.
    static let cacheScaleCeiling: CGFloat = 1.0

    private struct Key: Equatable {
        var revision: UInt64
        var canvasGeneration: Int
        var pixelSize: PixelSize
        var excluded: Set<UUID>
    }

    private var context: CGContext?
    private var cachedImage: CGImage?
    private var key: Key?

    /// Counts rebuilds — asserted by tests to prove a drag does not thrash.
    private(set) var rebuildCount = 0

    init() {}

    /// The committed image for this scene, rebuilding only when something it
    /// depends on actually changed.
    ///
    /// - Parameter revision: bumped on every scene mutation. NOT a `Scene ==`
    ///   check: deep-comparing thousands of objects on the equal path (the
    ///   common case) costs as much as the render it would avoid.
    func committedImage(for scene: Scene,
                        surfaces: SurfaceStore,
                        revision: UInt64,
                        excluding: Set<UUID>) -> CGImage? {
        let wanted = Key(revision: revision,
                         canvasGeneration: scene.canvasGeneration,
                         pixelSize: scene.canvas.pixelSize,
                         excluded: excluding)
        if wanted == key, let cachedImage { return cachedImage }

        let size = scene.canvas.pixelSize
        guard size.isValid else { return nil }

        // Reuse the backing context across rebuilds; only reallocate when the
        // canvas size changes.
        if context == nil || context?.width != size.width || context?.height != size.height {
            guard let fresh = PixelFormat.makeContext(
                width: size.width, height: size.height,
                colorSpace: scene.canvas.cgColorSpace) else { return nil }
            fresh.translateBy(x: 0, y: CGFloat(size.height))
            fresh.scaleBy(x: 1, y: -1)   // y-down, matching the renderer contract
            context = fresh
        }
        guard let ctx = context else { return nil }

        // Release the previous image BEFORE drawing. `makeImage()` is
        // copy-on-write, and drawing into the same context is exactly the write
        // that forces the deferred copy — holding the old image would keep two
        // full canvases live instead of one.
        cachedImage = nil

        ctx.saveGState()
        ctx.clear(size.rect)
        ctx.restoreGState()
        SceneRenderer.draw(scene, surfaces: surfaces, into: ctx, excluding: excluding)

        cachedImage = ctx.makeImage()
        key = wanted
        rebuildCount += 1
        return cachedImage
    }

    /// True when the cached image is valid for this state — lets the view skip
    /// even asking.
    func isValid(revision: UInt64, scene: Scene, excluding: Set<UUID>) -> Bool {
        key == Key(revision: revision,
                   canvasGeneration: scene.canvasGeneration,
                   pixelSize: scene.canvas.pixelSize,
                   excluded: excluding)
    }

    /// Drop everything. Called on canvas resize and document replacement.
    func invalidate() {
        cachedImage = nil
        context = nil
        key = nil
    }

    /// Approximate retained bytes — two full canvases at most.
    var byteCount: Int {
        var total = 0
        if let context { total += context.height * context.bytesPerRow }
        if let cachedImage { total += cachedImage.height * cachedImage.bytesPerRow }
        return total
    }
}
