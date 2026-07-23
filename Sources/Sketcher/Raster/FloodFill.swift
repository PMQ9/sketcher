import CoreGraphics
import Foundation

/// The one flood-fill core, shared by the bucket and the magic wand.
///
/// Both call `region(in:seed:…)` and differ only in what they do with the
/// returned mask — the bucket paints a color through it, the wand adopts it as
/// a selection. Sharing the function is deliberate: if the wand and bucket
/// computed "similar pixels" separately their tolerance would drift apart and
/// users would notice instantly (the plan calls this out by name).
///
/// `nonisolated` free functions over immutable images (invariant 11): a
/// full-canvas fill is ~10 ms and must not block the UI.
///
/// Comparison is on UN-premultiplied RGBA (invariant 10): premultiplied bytes
/// read darkened wherever alpha < 1, which on a transparent canvas is every
/// pixel, so a naive premultiplied compare makes bucket fill meaningless there.
/// Transparent matches transparent for free — both unpremultiply to (0,0,0,0).
enum FloodFill {
    /// The connected (or, when `contiguous == false`, global) set of pixels
    /// similar to the seed, as a full-page 8-bit gray mask (255 = in region,
    /// data row 0 == canvas top). `tolerance` is 0…1 of max per-channel distance.
    ///
    /// - contiguous: `true` for the bucket and the plain wand (flood from the
    ///   seed); `false` for Select Similar (every matching pixel, wand + Shift).
    static func region(in image: CGImage, seed: CGPoint, tolerance: CGFloat,
                       contiguous: Bool, canvas: CanvasSpec) -> CGImage? {
        let w = canvas.pixelSize.width, h = canvas.pixelSize.height
        guard w > 0, h > 0, let src = readBGRA(image, width: w, height: h) else { return nil }

        let sx = Int(seed.x.rounded(.down)), sy = Int(seed.y.rounded(.down))
        guard sx >= 0, sx < w, sy >= 0, sy < h else { return nil }

        let target = unpremultiply(r: src[(sy * w + sx) * 4 + 2],
                                   g: src[(sy * w + sx) * 4 + 1],
                                   b: src[(sy * w + sx) * 4 + 0],
                                   a: src[(sy * w + sx) * 4 + 3])
        let tol = max(tolerance, 0)

        @inline(__always) func matches(_ i: Int) -> Bool {
            let p = i * 4
            let c = unpremultiply(r: src[p + 2], g: src[p + 1], b: src[p + 0], a: src[p + 3])
            let d = max(max(abs(c.r - target.r), abs(c.g - target.g)),
                        max(abs(c.b - target.b), abs(c.a - target.a)))
            return d <= tol
        }

        var out = [UInt8](repeating: 0, count: w * h)

        if !contiguous {
            for i in 0..<(w * h) where matches(i) { out[i] = 255 }
            return MaskOps.writeGray(out, width: w, height: h)
        }

        // Scanline span fill with an EXPLICIT stack — never recursion, which
        // would blow the stack on a full-canvas fill. `out` doubles as the
        // visited set (255 == filled/visited).
        var stack: [(Int, Int)] = [(sx, sy)]
        while let (px, py) = stack.popLast() {
            guard out[py * w + px] == 0, matches(py * w + px) else { continue }
            // Extend the span left and right.
            var lx = px
            while lx - 1 >= 0, out[py * w + (lx - 1)] == 0, matches(py * w + (lx - 1)) { lx -= 1 }
            var rx = px
            while rx + 1 < w, out[py * w + (rx + 1)] == 0, matches(py * w + (rx + 1)) { rx += 1 }
            for x in lx...rx { out[py * w + x] = 255 }
            // Seed the rows above and below at the start of each matching run.
            for ny in [py - 1, py + 1] where ny >= 0 && ny < h {
                var x = lx
                while x <= rx {
                    if out[ny * w + x] == 0, matches(ny * w + x) {
                        stack.append((x, ny))
                        while x <= rx, matches(ny * w + x), out[ny * w + x] == 0 { x += 1 }
                    } else {
                        x += 1
                    }
                }
            }
        }
        return MaskOps.writeGray(out, width: w, height: h)
    }

    /// Read `image` into a top-down BGRA buffer (row 0 == canvas top), in the
    /// canonical premultiplied layout. A plain `.copy` draw round-trips a
    /// `CGImage` identically (top-left row order both sides), so a buffer row IS
    /// a canvas y — NOT `drawImageYDown`, which would add a second flip.
    static func readBGRA(_ image: CGImage, width w: Int, height h: Int) -> [UInt8]? {
        guard let ctx = PixelFormat.makeContext(width: w, height: h,
                                                colorSpace: CGColorSpaceCreateDeviceRGB()),
              let data = ctx.data else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let stride = ctx.bytesPerRow
        let src = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let s = y * stride, d = y * w * 4
            for x in 0..<(w * 4) { out[d + x] = src[s + x] }
        }
        return out
    }
}
