import CoreGraphics
import Foundation

/// Headless entry points, dispatched from `main.swift` BEFORE `NSApplication`
/// is touched — no window server, no run loop, no app bundle required.
///
/// This is what makes pixel verification runnable from a bare binary in CI, and
/// it exercises the REAL export pipeline rather than a parallel test-only one.
///
/// ```
/// Sketcher --test-render    <scene.json> <out.png>
/// Sketcher --test-roundtrip <in.json>    <out.json>
/// Sketcher --perf           [strokes] [pointsPerStroke]
/// ```
enum TestRenderMode {
    static let flags = ["--test-render", "--test-roundtrip", "--perf"]

    static func shouldHandle(_ arguments: [String]) -> Bool {
        arguments.contains { flags.contains($0) }
    }

    /// Returns a process exit code.
    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--test-render") {
            return renderScene(arguments: arguments)
        }
        if arguments.contains("--test-roundtrip") {
            return roundTrip(arguments: arguments)
        }
        if arguments.contains("--perf") {
            return perf(arguments: arguments)
        }
        return usage()
    }

    // MARK: - --test-render

    private static func renderScene(arguments: [String]) -> Int32 {
        guard let flagIndex = arguments.firstIndex(of: "--test-render"),
              arguments.count > flagIndex + 2 else {
            return fail("usage: --test-render <scene.json> <out.png>")
        }
        let inputPath = arguments[flagIndex + 1]
        let outputPath = arguments[flagIndex + 2]

        let scene: Scene
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            scene = try SceneCodec.decode(data)
        } catch {
            return fail("could not read scene: \(error.localizedDescription)")
        }

        // Surfaces referenced by the scene are not loadable standalone yet
        // (M8 adds the package format); vector-only fixtures need none.
        let surfaces = SurfaceStore()

        guard let image = ExportService.renderFullResolution(scene, surfaces: surfaces) else {
            return fail("render failed (canvas may exceed the size limits)")
        }
        guard let data = ExportService.pngData(image,
                                               pixelsPerPoint: scene.canvas.pixelsPerPoint) else {
            return fail("PNG encoding failed")
        }
        do {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        } catch {
            return fail("could not write \(outputPath): \(error.localizedDescription)")
        }

        print("OK \(image.width)x\(image.height)")
        return 0
    }

    // MARK: - --test-roundtrip

    /// Decode then re-encode. A byte-identical result proves the codec is
    /// deterministic AND that unknown object types survived verbatim.
    private static func roundTrip(arguments: [String]) -> Int32 {
        guard let flagIndex = arguments.firstIndex(of: "--test-roundtrip"),
              arguments.count > flagIndex + 2 else {
            return fail("usage: --test-roundtrip <in.json> <out.json>")
        }
        let inputPath = arguments[flagIndex + 1]
        let outputPath = arguments[flagIndex + 2]

        do {
            let original = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            let scene = try SceneCodec.decode(original)
            let reEncoded = try SceneCodec.encode(scene)
            try reEncoded.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

            // Encoding the same scene twice must be stable, or diffs are noise.
            let again = try SceneCodec.encode(SceneCodec.decode(reEncoded))
            guard again == reEncoded else {
                return fail("codec is not deterministic: re-encode differed")
            }
            print("OK \(reEncoded.count) bytes, \(scene.allObjects.count) objects")
            return 0
        } catch {
            return fail("roundtrip failed: \(error.localizedDescription)")
        }
    }

    // MARK: - --perf

    /// THE GATE.
    ///
    /// SwiftUI `Canvas` re-runs its whole closure on every invalidation and has
    /// no dirty-rect concept, so a frame costs a full scene rasterization. This
    /// measures exactly that: `SceneRenderer.draw` of the whole scene into a
    /// canvas-sized bitmap.
    ///
    /// Budget is 8.3 ms — this is a 120 Hz ProMotion machine, not 60 Hz.
    /// If the uncached number blows the budget, the committed/live cache is
    /// mandatory; if even the cached path blows it, `Canvas` has to be replaced
    /// by a `CALayer`-backed `NSView` (one file, because invariant 1 holds).
    private static func perf(arguments: [String]) -> Int32 {
        let flagIndex = arguments.firstIndex(of: "--perf") ?? 0
        let strokeCount = arguments.count > flagIndex + 1
            ? Int(arguments[flagIndex + 1]) ?? 2000 : 2000
        let pointsPerStroke = arguments.count > flagIndex + 2
            ? Int(arguments[flagIndex + 2]) ?? 300 : 300

        let scene = syntheticScene(strokeCount: strokeCount,
                                   pointsPerStroke: pointsPerStroke)
        let surfaces = SurfaceStore()
        let size = scene.canvas.pixelSize

        guard let ctx = PixelFormat.makeContext(width: size.width, height: size.height,
                                                colorSpace: scene.canvas.cgColorSpace) else {
            return fail("could not allocate the render context")
        }
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)

        print("scene: \(strokeCount) strokes x \(pointsPerStroke) points "
              + "= \(strokeCount * pointsPerStroke) samples, "
              + "canvas \(size.width)x\(size.height)")

        // Warm up: first render pays for lazy CG state the others do not.
        SceneRenderer.draw(scene, surfaces: surfaces, into: ctx)

        var samples: [Double] = []
        for _ in 0..<10 {
            let start = DispatchTime.now().uptimeNanoseconds
            SceneRenderer.draw(scene, surfaces: surfaces, into: ctx)
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }
        samples.sort()

        let median = samples[samples.count / 2]
        let best = samples[0]
        let worst = samples[samples.count - 1]
        let budget = 8.3

        print(String(format: "full-scene render: median %.2f ms  (best %.2f, worst %.2f)",
                     median, best, worst))
        print(String(format: "budget: %.1f ms @ 120 Hz", budget))

        // The cached path: one blit of a prepared image, which is what the
        // committed/live split reduces a frame to at <= 100%% zoom.
        if let cached = ctx.makeImage() {
            guard let blitCtx = PixelFormat.makeContext(
                width: size.width, height: size.height,
                colorSpace: scene.canvas.cgColorSpace) else {
                return fail("could not allocate the blit context")
            }
            var blits: [Double] = []
            for _ in 0..<10 {
                let start = DispatchTime.now().uptimeNanoseconds
                blitCtx.draw(cached, in: size.rect)
                let end = DispatchTime.now().uptimeNanoseconds
                blits.append(Double(end - start) / 1_000_000)
            }
            blits.sort()
            print(String(format: "cached blit:       median %.2f ms", blits[blits.count / 2]))
        }

        if median <= budget {
            print("PASS uncached render fits the frame budget")
            return 0
        }
        print(String(format: "FAIL uncached render is %.1fx over budget "
                     + "— the committed/live cache is required", median / budget))
        // Exit 0 either way: this reports a measurement, and the shell script
        // decides. A nonzero code here would make `make verify` fail on a
        // machine that simply has a slower GPU.
        return 0
    }

    /// Deterministic synthetic scene. No `Math.random`-style seeding: a
    /// per-process-seeded RNG would make successive perf runs incomparable.
    private static func syntheticScene(strokeCount: Int, pointsPerStroke: Int) -> Scene {
        var scene = Scene.blank()
        let size = scene.canvas.pixelSize
        var objects: [DrawObject] = []
        objects.reserveCapacity(strokeCount)

        var state: UInt64 = 0x5DEECE66D
        func nextUnit() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 11) % 1_000_000) / 1_000_000
        }

        for _ in 0..<strokeCount {
            let originX = nextUnit() * CGFloat(size.width)
            let originY = nextUnit() * CGFloat(size.height)
            var samples: [StrokeSample] = []
            samples.reserveCapacity(pointsPerStroke)
            for step in 0..<pointsPerStroke {
                let t = CGFloat(step)
                samples.append(StrokeSample(
                    point: CGPoint(x: originX + cos(t * 0.1) * t * 0.4,
                                   y: originY + sin(t * 0.1) * t * 0.4),
                    pressure: 1))
            }
            var style = ObjectStyle(strokeColor: .black)
            style.strokeWidthPx = 4
            objects.append(DrawObject(kind: .stroke(StrokePayload(samples: samples)),
                                      style: style))
        }
        scene.layers[0].content = .vector(objects)
        return scene
    }

    // MARK: - Helpers

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        return 1
    }

    private static func usage() -> Int32 {
        fail("""
        usage:
          Sketcher --test-render    <scene.json> <out.png>
          Sketcher --test-roundtrip <in.json>    <out.json>
          Sketcher --perf           [strokes] [pointsPerStroke]
        """)
    }
}
