import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

@Suite("Geometry")
struct GeometryTests {

    // MARK: - Hit testing

    @Test("Unfilled shapes hit on the border band, so you can click through them")
    func borderBandHitTest() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        var object = DrawObject(kind: .rectangle(rect: rect, cornerRadius: 0),
                                style: ObjectStyle(strokeColor: .black))
        object.style.fill = .none

        #expect(object.hitTest(CGPoint(x: 100, y: 150), tolerance: 4))   // on the edge
        #expect(!object.hitTest(CGPoint(x: 200, y: 200), tolerance: 4))  // dead center
    }

    @Test("A filled shape hits on its interior too")
    func filledInteriorHitTest() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        var object = DrawObject(kind: .rectangle(rect: rect, cornerRadius: 0),
                                style: ObjectStyle(strokeColor: .black))
        object.style.fill = .solid(.blue)

        #expect(object.hitTest(CGPoint(x: 200, y: 200), tolerance: 4))
    }

    @Test("Ellipse border test does not balloon along the major axis")
    func eccentricEllipseHitTest() {
        // A very wide, short ellipse. Scaling the ring deviation by min(a,b)
        // instead of |f|/|grad f| would make the whole middle band "hit".
        let rect = CGRect(x: 0, y: 0, width: 400, height: 40)
        let object = DrawObject(kind: .ellipse(rect: rect),
                                style: ObjectStyle(strokeColor: .black, strokeWidthPx: 1))

        #expect(object.hitTest(CGPoint(x: 200, y: 0), tolerance: 3))    // top of the arc
        #expect(!object.hitTest(CGPoint(x: 200, y: 20), tolerance: 3))  // dead center
    }

    @Test("A rotated shape hit-tests correctly via inverse transform")
    func rotatedHitTest() {
        let rect = CGRect(x: 100, y: 190, width: 200, height: 20)
        var object = DrawObject(kind: .rectangle(rect: rect, cornerRadius: 0),
                                style: ObjectStyle(strokeColor: .black, strokeWidthPx: 2))
        object.rotation = .pi / 2   // now a tall thin bar through the same center

        let center = rect.center
        // A point on the rotated shape's long edge: unrotated it is on the
        // horizontal edge, rotated it lands on the vertical one.
        let probe = CGPoint(x: center.x + 10, y: center.y + 90)
        #expect(object.hitTest(probe, tolerance: 4))
    }

    @Test("Hidden objects never hit")
    func hiddenNeverHits() {
        var object = DrawObject(kind: .rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                 cornerRadius: 0),
                                style: ObjectStyle(strokeColor: .black))
        object.isHidden = true
        #expect(!object.hitTest(CGPoint(x: 0, y: 50), tolerance: 4))
    }

    // MARK: - Resize

    @Test("Rotated resize keeps the opposite corner fixed in world space")
    func rotatedResizeAnchorsOppositeCorner() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        var object = DrawObject(kind: .rectangle(rect: rect, cornerRadius: 0),
                                style: ObjectStyle(strokeColor: .black))
        object.rotation = .pi / 6

        let fixedBefore = rect.oppositeCorner(.bottomRight)
            .rotated(around: rect.center, by: object.rotation)

        let resized = object.resized(handle: .bottomRight,
                                     to: CGPoint(x: 400, y: 350))
        guard case .rectangle(let newRect, _) = resized.kind else {
            Issue.record("expected a rectangle")
            return
        }
        let fixedAfter = newRect.oppositeCorner(.bottomRight)
            .rotated(around: newRect.center, by: resized.rotation)

        #expect(abs(fixedAfter.x - fixedBefore.x) < 1e-6)
        #expect(abs(fixedAfter.y - fixedBefore.y) < 1e-6)
    }

    @Test("Resizing from originals 200 times accumulates no drift")
    func resizeDoesNotDrift() {
        // The real bug this guards: recomputing from the PREVIOUS frame instead
        // of the original makes a long drag creep. Resizing repeatedly from the
        // original must land on exactly the same rect every time.
        let rect = CGRect(x: 50, y: 50, width: 300, height: 200)
        var object = DrawObject(kind: .rectangle(rect: rect, cornerRadius: 0),
                                style: ObjectStyle(strokeColor: .black))
        object.rotation = .pi / 5

        let target = CGPoint(x: 412.5, y: 337.25)
        let first = object.resized(handle: .topLeft, to: target)
        var last = first
        for _ in 0..<200 {
            last = object.resized(handle: .topLeft, to: target)
        }
        #expect(first.bounds == last.bounds)
    }

    // MARK: - Bounds

    @Test("Stroke render bounds account for brush width, including highlighter")
    func strokeRenderBoundsIncludeBrushWidth() {
        var brush = BrushSpec()
        brush.engine = .highlighter
        brush.sizePx = 10
        let payload = StrokePayload(samples: [StrokeSample(point: CGPoint(x: 100, y: 100))],
                                    brush: brush)
        let object = DrawObject(kind: .stroke(payload), style: ObjectStyle())

        // 3x multiplier => effective width 30 => pad 16 (half + 1).
        #expect(object.renderBounds.width >= 30)
    }

    @Test("CGRect(dragFrom:to:) normalizes a backwards drag")
    func dragRectNormalizes() {
        let r = CGRect(dragFrom: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 50))
        #expect(r == CGRect(x: 100, y: 50, width: 200, height: 200))
    }

    // MARK: - CanvasTransform

    @Test("Zoom keeps the canvas point under the cursor fixed")
    func zoomIsCursorAnchored() {
        // Randomized sequences, because the failure mode is cumulative drift
        // over many zoom steps rather than a single wrong result.
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for _ in 0..<100 {
            var transform = CanvasTransform(
                scale: CGFloat.random(in: 0.2...4, using: &generator),
                offset: CGPoint(x: CGFloat.random(in: -500...500, using: &generator),
                                y: CGFloat.random(in: -500...500, using: &generator)))
            let cursor = CGPoint(x: CGFloat.random(in: 0...1200, using: &generator),
                                 y: CGFloat.random(in: 0...800, using: &generator))
            let before = transform.toCanvas(cursor)

            for _ in 0..<10 {
                transform.zoom(by: CGFloat.random(in: 0.7...1.4, using: &generator),
                               about: cursor)
            }
            let after = transform.toCanvas(cursor)
            #expect(abs(after.x - before.x) < 1e-9)
            #expect(abs(after.y - before.y) < 1e-9)
        }
    }

    @Test("Zoom clamps to the supported range")
    func zoomClamps() {
        var transform = CanvasTransform(scale: 1, offset: .zero)
        for _ in 0..<100 { transform.zoom(by: 2, about: .zero) }
        #expect(transform.scale == CanvasTransform.maxScale)
        for _ in 0..<200 { transform.zoom(by: 0.5, about: .zero) }
        #expect(transform.scale == CanvasTransform.minScale)
    }

    @Test("toCanvas and toView round-trip")
    func transformRoundTrips() {
        let transform = CanvasTransform(scale: 0.37, offset: CGPoint(x: 121, y: -45))
        let p = CGPoint(x: 640, y: 480)
        let back = transform.toCanvas(transform.toView(p))
        #expect(abs(back.x - p.x) < 1e-9)
        #expect(abs(back.y - p.y) < 1e-9)
    }

    @Test("Hit tolerance stays constant on screen across zoom levels")
    func toleranceIsScreenConstant() {
        let zoomedOut = CanvasTransform(scale: 0.25, offset: .zero)
        let zoomedIn = CanvasTransform(scale: 4, offset: .zero)
        // 6 view points is a bigger canvas distance when zoomed out — that is
        // the point: the on-screen slop is what stays fixed.
        #expect(zoomedOut.canvasTolerance(viewPoints: 6) == 24)
        #expect(zoomedIn.canvasTolerance(viewPoints: 6) == 1.5)
    }
}

/// Deterministic RNG: `Hasher` is per-process seeded, so anything derived from
/// `hashValue` would make these tests non-reproducible across runs.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
