import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

// MARK: - Fixtures

private func canvas(_ w: Int, _ h: Int) -> CanvasSpec {
    CanvasSpec(pixelSize: PixelSize(width: w, height: h), background: .transparent)
}

/// A synthetic BGRA source: an opaque `color` rectangle on a transparent field.
private func sourceImage(_ w: Int, _ h: Int, rect: CGRect, color: RGBAColor) -> CGImage {
    let ctx = PixelFormat.makeContext(width: w, height: h,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // y-down
    ctx.setFillColor(color.cgColor)
    ctx.fill(rect)
    return ctx.makeImage()!
}

// MARK: - Mask orientation (defines the lift/fill contract)

@Suite("M7 Mask orientation")
struct MaskOrientationTests {
    /// The one fact everything downstream leans on: a mask's data row 0 is
    /// canvas y == 0 (top). Select the TOP half; the top must read selected and
    /// the bottom must not.
    @Test("A top-half region rasterizes to a top-half mask")
    func topHalfRasterizesUpright() {
        let store = SurfaceStore()
        let spec = canvas(40, 20)
        let mask = MaskOps.rasterize(.rect(CGRect(x: 0, y: 0, width: 40, height: 10)),
                                     canvas: spec, surfaces: store)!
        let buf = MaskOps.readGray(mask, width: 40, height: 20)!
        #expect(buf[5 * 40 + 20] > 127)    // y=5  (top)    selected
        #expect(buf[15 * 40 + 20] < 128)   // y=15 (bottom) not
    }

    /// The end-to-end contract the view model uses to lift and fill: a y-down
    /// context, `MaskOps.clip` through a MASK-backed region, paint. The paint
    /// must land in the TOP half — proving the centralized clip helper's
    /// compensating flip aligns a mask with where it was rasterized. If this
    /// ever flips, the fix is ONE flip, inside `MaskOps.clip`.
    @Test("MaskOps.clip paints a mask region where it was selected")
    func clipMatchesRasterOrientation() {
        let store = SurfaceStore()
        let spec = canvas(40, 20)
        let maskImage = MaskOps.rasterize(.rect(CGRect(x: 0, y: 0, width: 40, height: 10)),
                                          canvas: spec, surfaces: store)!
        let region = SelectionShape.mask(store.register(maskImage),
                                         bounds: MaskOps.nonEmptyBounds(maskImage, canvas: spec))
        let ctx = PixelFormat.makeContext(width: 40, height: 20, colorSpace: spec.cgColorSpace)!
        ctx.translateBy(x: 0, y: 20); ctx.scaleBy(x: 1, y: -1)   // y-down, as RasterOps does
        MaskOps.clip(region, in: ctx, canvas: spec, surfaces: store)
        ctx.setFillColor(RGBAColor.black.cgColor)
        ctx.fill(spec.pageRect)
        let painted = FloodFill.readBGRA(ctx.makeImage()!, width: 40, height: 20)!
        #expect(painted[(5 * 40 + 20) * 4 + 3] > 200)    // top painted
        #expect(painted[(15 * 40 + 20) * 4 + 3] < 50)    // bottom clear
    }
}

// MARK: - CGPath boolean combine (the Risk-2 spike, now a permanent test)

@Suite("M7 Region combine")
struct RegionCombineTests {
    private let store = SurfaceStore()
    private let spec = CanvasSpec(pixelSize: PixelSize(width: 300, height: 200),
                                  background: .transparent)

    @Test("Union of two rects is a compound spanning both")
    func unionSpansBoth() {
        let a = SelectionShape.rect(CGRect(x: 10, y: 10, width: 100, height: 100))
        let b = SelectionShape.rect(CGRect(x: 60, y: 60, width: 100, height: 100))
        let result = MaskOps.combine(a, b, mode: .union, canvas: spec, surfaces: store)
        guard case .compound = result else { #expect(Bool(false), "expected compound"); return }
        #expect(result!.bounds.width > 140)
        #expect(result!.bounds.height > 140)
    }

    @Test("Intersection is the overlap")
    func intersectionIsOverlap() {
        let a = SelectionShape.rect(CGRect(x: 10, y: 10, width: 100, height: 100))
        let b = SelectionShape.rect(CGRect(x: 60, y: 60, width: 100, height: 100))
        let result = MaskOps.combine(a, b, mode: .intersect, canvas: spec, surfaces: store)!
        #expect(abs(result.bounds.width - 50) < 2)
        #expect(abs(result.bounds.height - 50) < 2)
    }

    @Test("A self-intersecting figure-eight lasso fills both lobes")
    func figureEightFillsBothLobes() {
        // ∞ pinched at (100,50): the sloppy-lasso case CGPath booleans choke on.
        let pts = [CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100),
                   CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 0),
                   CGPoint(x: 100, y: 50)]
        let lasso = SelectionShape.polygon(points: pts, evenOdd: false)
        let mask = MaskOps.rasterize(lasso, canvas: spec, surfaces: store)!
        let buf = MaskOps.readGray(mask, width: 300, height: 200)!
        func filled(_ box: CGRect) -> Int {
            var n = 0
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) where buf[y * 300 + x] > 127 { n += 1 }
            }
            return n
        }
        #expect(filled(CGRect(x: 20, y: 40, width: 40, height: 20)) > 300)    // left lobe
        #expect(filled(CGRect(x: 140, y: 40, width: 40, height: 20)) > 300)   // right lobe
    }

    @Test("Subtract removes the punched region, keeps the rest")
    func subtractKeepsRemainder() {
        let base = SelectionShape.rect(CGRect(x: 0, y: 0, width: 200, height: 100))
        let hole = SelectionShape.rect(CGRect(x: 140, y: 20, width: 40, height: 40))
        let result = MaskOps.combine(base, hole, mode: .subtract, canvas: spec, surfaces: store)!
        let mask = MaskOps.rasterize(result, canvas: spec, surfaces: store)!
        let buf = MaskOps.readGray(mask, width: 300, height: 200)!
        #expect(buf[50 * 300 + 20] > 127)     // far from the hole: still selected
        #expect(buf[40 * 300 + 160] < 128)    // inside the hole: cleared
    }

    @Test("Combining with a mask operand yields a mask")
    func maskOperandStaysMask() {
        // Force a mask by wand-filling, then union a rect onto it.
        let src = sourceImage(300, 200, rect: CGRect(x: 0, y: 0, width: 80, height: 200),
                              color: .black)
        let regionImage = FloodFill.region(in: src, seed: CGPoint(x: 40, y: 100),
                                           tolerance: 0.1, contiguous: true, canvas: spec)!
        let wand = SelectionShape.mask(store.register(regionImage),
                                       bounds: MaskOps.nonEmptyBounds(regionImage, canvas: spec))
        let rect = SelectionShape.rect(CGRect(x: 200, y: 0, width: 80, height: 200))
        let result = MaskOps.combine(wand, rect, mode: .union, canvas: spec, surfaces: store)
        guard case .mask = result else { #expect(Bool(false), "expected mask"); return }
        #expect(result!.bounds.width > 250)    // spans wand column + rect column
    }
}

// MARK: - Flood fill (shared by wand + bucket)

@Suite("M7 FloodFill")
struct FloodFillTests {
    private let spec = CanvasSpec(pixelSize: PixelSize(width: 100, height: 100),
                                  background: .transparent)

    @Test("A contiguous fill covers the seeded shape and nothing else")
    func contiguousCoversShape() {
        let src = sourceImage(100, 100, rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                              color: .black)
        let region = FloodFill.region(in: src, seed: CGPoint(x: 40, y: 40),
                                      tolerance: 0.1, contiguous: true, canvas: spec)!
        let bounds = MaskOps.nonEmptyBounds(region, canvas: spec)
        #expect(abs(bounds.minX - 20) < 2 && abs(bounds.width - 40) < 3)
        let buf = MaskOps.readGray(region, width: 100, height: 100)!
        #expect(buf[40 * 100 + 40] > 127)    // inside the square
        #expect(buf[5 * 100 + 5] < 128)      // transparent corner untouched
    }

    @Test("Transparent matches transparent (fill the empty field)")
    func transparentMatchesTransparent() {
        let src = sourceImage(100, 100, rect: CGRect(x: 40, y: 40, width: 20, height: 20),
                              color: .black)
        let region = FloodFill.region(in: src, seed: CGPoint(x: 2, y: 2),
                                      tolerance: 0.05, contiguous: true, canvas: spec)!
        let buf = MaskOps.readGray(region, width: 100, height: 100)!
        #expect(buf[2 * 100 + 2] > 127)       // transparent field is selected
        #expect(buf[49 * 100 + 49] < 128)     // the opaque square is NOT
    }

    @Test("A fill inside an antialiased circle leaks zero pixels and leaves no halo")
    func fillInsideCircleNoLeak() {
        // White field, an antialiased black ring; flood the interior.
        let ctx = PixelFormat.makeContext(width: 100, height: 100,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        ctx.translateBy(x: 0, y: 100); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(RGBAColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(RGBAColor.black.cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: 25, y: 25, width: 50, height: 50))
        let src = ctx.makeImage()!

        let region = FloodFill.region(in: src, seed: CGPoint(x: 50, y: 50),
                                      tolerance: 0.25, contiguous: true, canvas: spec)!
        let buf = MaskOps.readGray(region, width: 100, height: 100)!
        #expect(buf[50 * 100 + 50] > 127)     // interior filled
        #expect(buf[50 * 100 + 48] > 127)     // right up to the ring — no inner halo
        #expect(buf[2 * 100 + 2] < 128)       // outside the ring: the fill did NOT leak
        #expect(buf[50 * 100 + 90] < 128)     // outside, past the ring: also not leaked
    }

    @Test("The wand and the bucket share one flood-fill, so tolerance can't diverge")
    func wandAndBucketShareFloodFill() {
        let src = sourceImage(100, 100, rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                              color: .black)
        let seed = CGPoint(x: 40, y: 40)
        // The wand's region and the bucket's region are the SAME call, so identical.
        let a = FloodFill.region(in: src, seed: seed, tolerance: 0.1, contiguous: true, canvas: spec)!
        let b = FloodFill.region(in: src, seed: seed, tolerance: 0.1, contiguous: true, canvas: spec)!
        #expect(MaskOps.readGray(a, width: 100, height: 100)!
            == MaskOps.readGray(b, width: 100, height: 100)!)
    }

    @Test("Non-contiguous select-similar grabs every matching pixel")
    func nonContiguousGrabsAll() {
        // Two separate black squares; select-similar from one grabs both.
        let ctx = PixelFormat.makeContext(width: 100, height: 100,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        ctx.translateBy(x: 0, y: 100); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(RGBAColor.black.cgColor)
        ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        ctx.fill(CGRect(x: 70, y: 70, width: 20, height: 20))
        let src = ctx.makeImage()!
        let region = FloodFill.region(in: src, seed: CGPoint(x: 20, y: 20),
                                      tolerance: 0.1, contiguous: false, canvas: spec)!
        let buf = MaskOps.readGray(region, width: 100, height: 100)!
        #expect(buf[20 * 100 + 20] > 127)     // seeded square
        #expect(buf[80 * 100 + 80] > 127)     // the far square, too
    }
}

// MARK: - Mask trace (wand ants)

@Suite("M7 MaskTrace")
struct MaskTraceTests {
    private let store = SurfaceStore()
    private let spec = CanvasSpec(pixelSize: PixelSize(width: 100, height: 100),
                                  background: .transparent)

    @Test("A rect mask traces to one contour matching its bounds")
    func rectTracesToOneContour() {
        let mask = MaskOps.rasterize(.rect(CGRect(x: 20, y: 30, width: 40, height: 25)),
                                     canvas: spec, surfaces: store)!
        let contours = MaskTrace.contours(of: mask, canvas: spec)
        #expect(contours.count == 1)
        let b = CGRect(containing: contours[0])
        #expect(abs(b.minX - 20) < 2 && abs(b.minY - 30) < 2)
        #expect(abs(b.width - 40) < 3 && abs(b.height - 25) < 3)
    }

    @Test("A region with a hole traces to two contours")
    func holeTracesToTwoContours() {
        let outer = SelectionShape.rect(CGRect(x: 10, y: 10, width: 80, height: 80))
        let hole = SelectionShape.rect(CGRect(x: 35, y: 35, width: 30, height: 30))
        let donut = MaskOps.combine(outer, hole, mode: .subtract, canvas: spec, surfaces: store)!
        let mask = MaskOps.rasterize(donut, canvas: spec, surfaces: store)!
        #expect(MaskTrace.contours(of: mask, canvas: spec).count == 2)
    }
}

// MARK: - Grow / shrink / feather / invert

@Suite("M7 Mask morphology")
struct MaskMorphologyTests {
    private let store = SurfaceStore()
    private let spec = CanvasSpec(pixelSize: PixelSize(width: 120, height: 120),
                                  background: .transparent)
    private var square: SelectionShape {
        .rect(CGRect(x: 40, y: 40, width: 40, height: 40))
    }

    private func selectedCount(_ shape: SelectionShape) -> Int {
        let mask = MaskOps.rasterize(shape, canvas: spec, surfaces: store)!
        return MaskOps.readGray(mask, width: 120, height: 120)!.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
    }

    @Test("Grow enlarges, shrink reduces")
    func growAndShrink() {
        let base = selectedCount(square)
        let grown = MaskOps.morphology(square, deltaPx: 6, canvas: spec, surfaces: store)!
        let shrunk = MaskOps.morphology(square, deltaPx: -6, canvas: spec, surfaces: store)!
        #expect(selectedCount(grown) > base)
        #expect(selectedCount(shrunk) < base)
    }

    @Test("Invert flips the selected area within the page")
    func invertFlips() {
        let base = selectedCount(square)
        let inverted = MaskOps.invert(square, canvas: spec, surfaces: store)!
        let invCount = selectedCount(inverted)
        #expect(abs((base + invCount) - 120 * 120) < 200)   // partition of the page
    }

    @Test("Feather keeps a soft-but-present region")
    func featherKeepsRegion() {
        let feathered = MaskOps.feather(square, radiusPx: 3, canvas: spec, surfaces: store)
        #expect(feathered != nil)
        #expect(!feathered!.bounds.isEmpty)
    }
}
