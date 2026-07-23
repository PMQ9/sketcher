import CoreGraphics
import CoreImage
import Foundation

/// Selection-mask algebra: rasterize a region to an 8-bit gray mask, combine
/// two regions, and grow / shrink / feather / invert.
///
/// `nonisolated` free functions over immutable images (invariant 11): selection
/// math must run off-main, and it produces new immutable surfaces like every
/// other raster op.
///
/// TWO representations, chosen by whether the operands are path-expressible:
///   • analytic (rect / ellipse / polygon / compound) combine through native
///     `CGPath` booleans → a value-typed `.compound`. Exact, cheap, no trace.
///   • anything mask-backed (the wand) combines per-pixel → a `.mask`.
///
/// MASK ORIENTATION, fixed once and asserted by `maskTopHalfSelectsTopHalf`:
/// a mask's data row 0 == canvas y == 0 (top), exactly like every surface in
/// this app, which are all made from y-down-flipped contexts. `grayContext`
/// callers that draw canvas-space geometry flip the same way `RasterOps` does.
enum MaskOps {
    /// 8-bit DeviceGray, `alphaInfo .none`. NOT alphaOnly — `clip(to:mask:)`
    /// rejects that outright (T2). Polarity: 255 = selected, 0 = not. Zero-filled
    /// (all-unselected) on creation.
    static func grayContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0,
              width <= CanvasSpec.maxSide, height <= CanvasSpec.maxSide,
              width * height <= CanvasSpec.maxPixels else { return nil }
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    // MARK: - Rasterize a region to a full-page mask

    /// A fresh full-page gray mask for any region. Masks are page-sized so a
    /// per-pixel combine and a `clip(to: pageRect, mask:)` both align 1:1 with
    /// no bounds bookkeeping; the tight box lives in the region's `bounds`.
    static func rasterize(_ shape: SelectionShape, canvas: CanvasSpec,
                          surfaces: SurfaceStore) -> CGImage? {
        if case .mask(let id, _) = shape { return surfaces.image(id) }
        let size = canvas.pixelSize
        guard let ctx = grayContext(width: size.width, height: size.height),
              let path = shape.makePath() else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)   // y-down, so canvas geometry lands upright
        ctx.addPath(path)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath(using: shape.usesEvenOdd ? .evenOdd : .winding)
        return ctx.makeImage()
    }

    // MARK: - Top-level combine

    /// Combine the existing region with a freshly-drawn one. Analytic pairs go
    /// through `CGPath` booleans and stay `.compound`; anything mask-backed
    /// rasterizes and combines per-pixel. Registers ONLY the final mask (any
    /// intermediates are plain locals), so the store never fills with orphans.
    static func combine(_ existing: SelectionShape?, _ new: SelectionShape,
                        mode: CombineMode, canvas: CanvasSpec,
                        surfaces: SurfaceStore) -> SelectionShape? {
        guard mode != .replace, let existing else { return new }

        // Path × path → boolean → compound. Always winding: the booleans emit
        // holes wound opposite to their outer contour, which a winding refill
        // reproduces exactly, and the decomposition preserves subpath direction.
        if let pa = existing.makePath(), let pb = new.makePath() {
            let result: CGPath
            switch mode {
            case .union: result = pa.union(pb, using: .winding)
            case .subtract: result = pa.subtracting(pb, using: .winding)
            case .intersect: result = pa.intersection(pb, using: .winding)
            case .replace: result = pb
            }
            let geometry = result.selectionGeometry()
            return geometry.isEmpty ? nil : .compound(geometry)
        }

        // Mask involved → per-pixel.
        guard let ma = rasterize(existing, canvas: canvas, surfaces: surfaces),
              let mb = rasterize(new, canvas: canvas, surfaces: surfaces),
              let combined = combineMasks(ma, mb, mode: mode, canvas: canvas)
        else { return nil }
        return registerMask(combined, canvas: canvas, surfaces: surfaces)
    }

    /// Per-pixel combine of two full-page gray masks. `subtract` is
    /// `min(a, 255−b)` so a feathered edge subtracts smoothly, not just at the
    /// binary boundary.
    static func combineMasks(_ a: CGImage, _ b: CGImage, mode: CombineMode,
                             canvas: CanvasSpec) -> CGImage? {
        let w = canvas.pixelSize.width, h = canvas.pixelSize.height
        guard let bufA = readGray(a, width: w, height: h),
              let bufB = readGray(b, width: w, height: h) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let va = Int(bufA[i]), vb = Int(bufB[i])
            let v: Int
            switch mode {
            case .union: v = max(va, vb)
            case .intersect: v = min(va, vb)
            case .subtract: v = min(va, 255 - vb)
            case .replace: v = vb
            }
            out[i] = UInt8(v)
        }
        return writeGray(out, width: w, height: h)
    }

    // MARK: - Grow / shrink / feather / invert

    /// Grow (`deltaPx` > 0) or shrink (< 0) the region by a pixel radius, via
    /// `CIMorphologyMaximum` / `Minimum`. Always returns a `.mask` — the result
    /// is no longer path-expressible.
    static func morphology(_ shape: SelectionShape, deltaPx: CGFloat,
                           canvas: CanvasSpec, surfaces: SurfaceStore) -> SelectionShape? {
        guard abs(deltaPx) >= 0.5,
              let mask = rasterize(shape, canvas: canvas, surfaces: surfaces) else { return nil }
        let ci = CIImage(cgImage: mask)
        let name = deltaPx > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(abs(deltaPx), forKey: "inputRadius")
        return renderCI(filter.outputImage, extent: ci.extent,
                        canvas: canvas, surfaces: surfaces)
    }

    /// Soften the region boundary with a Gaussian blur — the feather. Kept as a
    /// mask so `clip(to:mask:)` yields the soft edge on fill and lift.
    static func feather(_ shape: SelectionShape, radiusPx: CGFloat,
                        canvas: CanvasSpec, surfaces: SurfaceStore) -> SelectionShape? {
        guard radiusPx >= 0.5,
              let mask = rasterize(shape, canvas: canvas, surfaces: surfaces),
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        let ci = CIImage(cgImage: mask)
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radiusPx, forKey: kCIInputRadiusKey)
        return renderCI(filter.outputImage, extent: ci.extent,
                        canvas: canvas, surfaces: surfaces)
    }

    /// The complement within the page — Invert Selection.
    static func invert(_ shape: SelectionShape, canvas: CanvasSpec,
                       surfaces: SurfaceStore) -> SelectionShape? {
        guard let mask = rasterize(shape, canvas: canvas, surfaces: surfaces) else { return nil }
        let w = canvas.pixelSize.width, h = canvas.pixelSize.height
        guard let buf = readGray(mask, width: w, height: h) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = 255 &- buf[i] }
        guard let image = writeGray(out, width: w, height: h) else { return nil }
        return registerMask(image, canvas: canvas, surfaces: surfaces)
    }

    // MARK: - Clipping

    /// Intersect `ctx`'s clip with `shape`. `ctx` MUST be the y-down flipped
    /// canvas context every `RasterOps` routine uses (the lift, fill, and stroke
    /// paths all are). This is the ONE place selection clipping happens, so the
    /// orientation quirk below is stated once and never re-derived:
    ///
    ///   • A path shape adds its path and clips by its fill rule — paths ride
    ///     the CTM, so this is upright with no fuss.
    ///   • `clip(to:mask:)` does NOT: in a flipped context it maps the mask like
    ///     `draw` does (row 0 → the bottom), the opposite of our row-0-is-top
    ///     mask storage. One compensating vertical flip aligns it, proven by
    ///     `clipMatchesRasterOrientation`.
    static func clip(_ shape: SelectionShape, in ctx: CGContext,
                     canvas: CanvasSpec, surfaces: SurfaceStore) {
        if let path = shape.makePath() {
            ctx.addPath(path)
            ctx.clip(using: shape.usesEvenOdd ? .evenOdd : .winding)
        } else if case .mask(let id, _) = shape, let mask = surfaces.image(id),
                  let flipped = flippedVertically(mask, canvas: canvas) {
            ctx.clip(to: canvas.pageRect, mask: flipped)
        } else {
            ctx.clip(to: .zero)   // unknown/empty region clips everything away
        }
    }

    /// A vertically-flipped copy — the compensating flip for `clip(to:mask:)`.
    static func flippedVertically(_ image: CGImage, canvas: CanvasSpec) -> CGImage? {
        let w = canvas.pixelSize.width, h = canvas.pixelSize.height
        guard let ctx = grayContext(width: w, height: h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Bounds

    /// Tight box (canvas pixels, top-left) of the selected pixels, or `.null`.
    /// Data row 0 == canvas y == 0, so a buffer row index IS a canvas y.
    static func nonEmptyBounds(_ mask: CGImage, canvas: CanvasSpec) -> CGRect {
        let w = canvas.pixelSize.width, h = canvas.pixelSize.height
        guard let buf = readGray(mask, width: w, height: h) else { return .null }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w where buf[row + x] > 127 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Raw gray IO (one orientation, matched pair)

    /// Read a mask's bytes top-down (row 0 == canvas top). A plain `draw` into a
    /// bitmap context round-trips a `CGImage` identically (both use top-left row
    /// order), so the buffer's row 0 IS the image's row 0 — which `rasterize`
    /// and every surface define as canvas top. NOT `drawImageYDown`, which would
    /// add a second flip.
    static func readGray(_ image: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        guard let ctx = grayContext(width: w, height: h), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let stride = ctx.bytesPerRow
        let src = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let s = y * stride, d = y * w
            for x in 0..<w { out[d + x] = src[s + x] }
        }
        return out
    }

    /// Inverse of `readGray`: pack a top-down buffer into a fresh gray image
    /// whose data row 0 is canvas top — the invariant every consumer expects.
    static func writeGray(_ buffer: [UInt8], width w: Int, height h: Int) -> CGImage? {
        guard buffer.count == w * h, let ctx = grayContext(width: w, height: h),
              let data = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        let dst = data.bindMemory(to: UInt8.self, capacity: stride * h)
        for y in 0..<h {
            let s = y * w, d = y * stride
            for x in 0..<w { dst[d + x] = buffer[s + x] }
        }
        // The context is unflipped, so its makeImage() already reports row 0 as
        // the first memory row == our buffer row 0 == canvas top.
        return ctx.makeImage()
    }

    // MARK: - Helpers

    private static func registerMask(_ image: CGImage, canvas: CanvasSpec,
                                     surfaces: SurfaceStore) -> SelectionShape? {
        let bounds = nonEmptyBounds(image, canvas: canvas)
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        return .mask(surfaces.register(image), bounds: bounds)
    }

    private static func renderCI(_ output: CIImage?, extent: CGRect,
                                 canvas: CanvasSpec, surfaces: SurfaceStore) -> SelectionShape? {
        guard let output else { return nil }
        // Crop back to the page (clamp produced infinite extent) and render
        // gray, so the result stays a clip-compatible DeviceGray mask.
        let cropped = output.cropped(to: extent)
        guard let cg = CIContextProvider.shared.createCGImage(
            cropped, from: CGRect(x: 0, y: 0,
                                  width: canvas.pixelSize.width,
                                  height: canvas.pixelSize.height),
            format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        return registerMask(cg, canvas: canvas, surfaces: surfaces)
    }
}

// MARK: - CGPath decomposition

extension CGPath {
    /// Flatten to closed polyline subpaths, preserving each subpath's direction,
    /// for storage in a value-typed `PathGeometry`. `CGPath` booleans already
    /// emit line segments for straight input and beziers only where a curved
    /// operand (an ellipse) was involved; those are subdivided here. Direction
    /// is preserved so a boolean's oppositely-wound holes survive a winding
    /// refill. Stored as winding (`evenOdd: false`).
    func selectionGeometry(flatness: CGFloat = 0.6) -> PathGeometry {
        var subpaths: [[CGPoint]] = []
        var current: [CGPoint] = []

        applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                if current.count >= 2 { subpaths.append(current) }
                current = [element.points[0]]
            case .addLineToPoint:
                current.append(element.points[0])
            case .addQuadCurveToPoint:
                guard let from = current.last else { break }
                Self.appendQuad(&current, from: from,
                                control: element.points[0], to: element.points[1],
                                flatness: flatness)
            case .addCurveToPoint:
                guard let from = current.last else { break }
                Self.appendCubic(&current, from: from,
                                 c1: element.points[0], c2: element.points[1],
                                 to: element.points[2], flatness: flatness)
            case .closeSubpath:
                if current.count >= 2 { subpaths.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if current.count >= 2 { subpaths.append(current) }
        return PathGeometry(subpaths: subpaths, evenOdd: false)
    }

    private static func curveSteps(_ points: [CGPoint], flatness: CGFloat) -> Int {
        var length: CGFloat = 0
        for i in 1..<points.count { length += points[i - 1].distance(to: points[i]) }
        return max(2, min(64, Int((length / max(flatness * 6, 1)).rounded(.up))))
    }

    private static func appendQuad(_ out: inout [CGPoint], from: CGPoint,
                                   control: CGPoint, to: CGPoint, flatness: CGFloat) {
        let n = curveSteps([from, control, to], flatness: flatness)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n), u = 1 - t
            let x = u * u * from.x + 2 * u * t * control.x + t * t * to.x
            let y = u * u * from.y + 2 * u * t * control.y + t * t * to.y
            out.append(CGPoint(x: x, y: y))
        }
    }

    private static func appendCubic(_ out: inout [CGPoint], from: CGPoint,
                                    c1: CGPoint, c2: CGPoint, to: CGPoint,
                                    flatness: CGFloat) {
        let n = curveSteps([from, c1, c2, to], flatness: flatness)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n), u = 1 - t
            let x = u*u*u*from.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*to.x
            let y = u*u*u*from.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*to.y
            out.append(CGPoint(x: x, y: y))
        }
    }
}
