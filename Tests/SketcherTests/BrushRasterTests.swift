import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

// MARK: - Freehand geometry

@Suite("M6 Freehand")
struct FreehandTests {
    private func line(_ xs: [CGFloat], y: CGFloat = 0, pressure: CGFloat = 0.5)
        -> [Freehand.InputPoint] {
        xs.map { Freehand.InputPoint(point: CGPoint(x: $0, y: y), pressure: pressure) }
    }

    @Test("A click becomes a small filled blob about the brush size")
    func clickIsADot() {
        let outline = Freehand.outline([Freehand.InputPoint(point: CGPoint(x: 50, y: 50),
                                                            pressure: 0.5)],
                                       options: Freehand.Options(size: 16, thinning: 0.5))
        #expect(outline.count >= 3)
        let box = CGRect(containing: outline)
        // Nominal radius at pressure 0.5, thinning 0.5 is size/2, so ~size across.
        #expect(box.width > 8 && box.width < 30)
        #expect(box.height > 8 && box.height < 30)
    }

    @Test("A repeated identical point is a round dot, not a degenerate sliver")
    func identicalPointsAreARing() {
        let p = Freehand.InputPoint(point: CGPoint(x: 10, y: 10), pressure: 1)
        let outline = Freehand.outline([p, p, p], options: Freehand.Options(size: 20))
        #expect(outline.count >= 8)
        let center = CGPoint(x: 10, y: 10)
        // A round dot: every ring point is the SAME distance from the center.
        let radius = outline[0].distance(to: center)
        #expect(radius > 1)
        for pt in outline {
            #expect(abs(pt.distance(to: center) - radius) < 0.5)
        }
    }

    @Test("A constant-width stroke has a height near the brush size along its length")
    func constantWidthMatchesSize() {
        let outline = Freehand.outline(line([0, 40, 80, 120]),
                                       options: Freehand.Options(size: 20, thinning: 0,
                                                                 simulatePressure: false))
        let box = CGRect(containing: outline)
        #expect(box.height > 16 && box.height < 24)     // ~= size
        #expect(box.width > 120 && box.width < 145)     // length + round caps
    }

    @Test("Pressure drives width when thinning is on")
    func pressureDrivesWidth() {
        let opts = Freehand.Options(size: 40, thinning: 1, simulatePressure: false)
        let heavy = CGRect(containing: Freehand.outline(line([0, 40, 80], pressure: 1.0),
                                                        options: opts)).height
        let light = CGRect(containing: Freehand.outline(line([0, 40, 80], pressure: 0.1),
                                                        options: opts)).height
        #expect(heavy > light * 2)
    }

    @Test("The outline is deterministic")
    func deterministic() {
        let pts = line([0, 30, 60, 90])
        let a = Freehand.outline(pts, options: Freehand.Options())
        let b = Freehand.outline(pts, options: Freehand.Options())
        #expect(a == b)
    }
}

// MARK: - Stabilizer

@Suite("M6 OneEuroFilter")
struct OneEuroFilterTests {
    @Test("The first sample passes through untouched")
    func firstSamplePassesThrough() {
        var filter = OneEuroFilter()
        let p = CGPoint(x: 42, y: 17)
        #expect(filter.filter(p, dt: 0) == p)
    }

    @Test("Jitter around a path is reduced")
    func reducesJitter() {
        // A steady rightward drift with alternating vertical jitter.
        var raw: [CGPoint] = []
        for i in 0..<40 {
            raw.append(CGPoint(x: CGFloat(i) * 4, y: (i % 2 == 0 ? 5 : -5)))
        }
        var filter = OneEuroFilter.forStreamline(0.9)
        var filtered: [CGPoint] = []
        for (i, p) in raw.enumerated() {
            filtered.append(filter.filter(p, dt: i == 0 ? 0 : 1.0 / 120))
        }
        // Deviation from the y=0 centerline should shrink after warm-up.
        func spread(_ pts: [CGPoint]) -> CGFloat {
            pts.dropFirst(10).map { abs($0.y) }.reduce(0, +) / CGFloat(pts.count - 10)
        }
        #expect(spread(filtered) < spread(raw) * 0.6)
    }

    @Test("Fast straight motion is barely lagged")
    func fastMotionLowLag() {
        var filter = OneEuroFilter.forStreamline(0.5)
        var last = CGPoint.zero
        for i in 0..<20 {
            last = filter.filter(CGPoint(x: CGFloat(i) * 60, y: 0), dt: i == 0 ? 0 : 1.0 / 120)
        }
        // After a fast run the filtered point trails the raw (1140) only slightly.
        #expect(last.x > 1000)
    }
}

// MARK: - Brush presets

@Suite("M6 BrushEngine")
struct BrushEngineTests {
    private func stroke(_ engine: BrushSpec.Engine) -> StrokePayload {
        var brush = BrushSpec(); brush.engine = engine; brush.sizePx = 12
        return StrokePayload(samples: (0..<6).map {
            StrokeSample(point: CGPoint(x: CGFloat($0) * 20, y: 0), pressure: 0.7)
        }, brush: brush)
    }

    @Test("Every preset renders a non-empty outline")
    func everyPresetDraws() {
        for engine in BrushSpec.Engine.cycleOrder {
            #expect(BrushEngine.outline(for: stroke(engine)).count >= 3)
        }
    }

    @Test("The highlighter is wide and multiplies")
    func highlighter() {
        var brush = BrushSpec(); brush.engine = .highlighter
        #expect(brush.widthMultiplier == 3)
        #expect(brush.blendMode == .multiply)
    }

    @Test("Shift+B cycles through all six presets and wraps")
    func cycleWraps() {
        var engine = BrushSpec.Engine.pen
        var seen: [BrushSpec.Engine] = [engine]
        for _ in 0..<6 { engine = engine.next; seen.append(engine) }
        #expect(Set(seen.dropLast()).count == 6)   // visited all six
        #expect(seen.last == .pen)                  // and wrapped back
    }

    @Test("Calligraphy modulates pressure by stroke direction")
    func calligraphyModulates() {
        var brush = BrushSpec(); brush.engine = .calligraphy
        // An L-shape: horizontal then vertical, so direction changes.
        let payload = StrokePayload(samples: [
            StrokeSample(point: CGPoint(x: 0, y: 0)),
            StrokeSample(point: CGPoint(x: 40, y: 0)),
            StrokeSample(point: CGPoint(x: 40, y: 40)),
        ], brush: brush)
        let pressures = BrushEngine.inputPoints(for: payload).map(\.pressure)
        #expect(Set(pressures).count > 1)   // not a constant
    }
}
