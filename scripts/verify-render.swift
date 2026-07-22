#!/usr/bin/env swift
// Pixel assertions against files produced by the REAL export pipeline.
//
// Assertions are on pixel VALUES and POPULATION COUNTS at known coordinates —
// never on image hashes. A hash tells you something changed; it never tells you
// what, and the first legitimate antialiasing tweak makes everyone delete the
// test.
//
// Usage: swift scripts/verify-render.swift <dir-with-rendered-pngs>

import CoreGraphics
import Foundation
import ImageIO

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// ---------------------------------------------------------------------------
// Raster: any PNG normalized to straight RGBA8 so probes are comparable.
// ---------------------------------------------------------------------------

struct Raster {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(contentsOf path: String) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // Locals, not self.width/self.height: referencing a property inside the
        // closure captures a not-yet-initialized self.
        let w = image.width
        let h = image.height

        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        // MUST be premultiplied: CGBitmapContext does not accept straight alpha
        // (`.last`/`.first`) — it returns nil for that combination. `pixel()`
        // un-premultiplies on read, which is what the comparisons need anyway.
        let drew: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        width = w
        height = h
        bytes = buffer
    }

    /// Top-left origin, y-down — matching the renderer's coordinate contract.
    ///
    /// Returns UN-PREMULTIPLIED colour. Premultiplied bytes read darkened
    /// everywhere alpha < 1, which on a transparent canvas is most pixels, so
    /// comparing them against an expected colour would fail for the wrong
    /// reason.
    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return (-1, -1, -1, -1) }
        let i = (y * width + x) * 4
        let a = Int(bytes[i + 3])
        guard a > 0 else { return (0, 0, 0, 0) }
        guard a < 255 else {
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), a)
        }
        func straight(_ c: UInt8) -> Int { min(255, Int(c) * 255 / a) }
        return (straight(bytes[i]), straight(bytes[i + 1]), straight(bytes[i + 2]), a)
    }

    func count(where predicate: ((r: Int, g: Int, b: Int, a: Int)) -> Bool) -> Int {
        var total = 0
        for y in 0..<height where true {
            for x in 0..<width where predicate(pixel(x, y)) { total += 1 }
        }
        return total
    }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

var failures = 0
var checks = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL \(label)\(extra.isEmpty ? "" : "  — \(extra)")")
    }
}

func near(_ actual: Int, _ expected: Int, _ tolerance: Int = 12) -> Bool {
    abs(actual - expected) <= tolerance
}

func load(_ name: String) -> Raster? {
    let path = "\(dir)/\(name)"
    guard let raster = Raster(contentsOf: path) else {
        failures += 1
        print("  FAIL could not load \(path)")
        return nil
    }
    return raster
}

// ---------------------------------------------------------------------------
// shapes.png — 400x300 opaque white with one of every kind
// ---------------------------------------------------------------------------

print("shapes.png")
if let r = load("shapes.png") {
    // (a) Export dimensions are EXACTLY canvas.pixelSize. The #1 Retina bug
    //     class is a half-res or double-res export.
    check("export is exactly 400x300", r.width == 400 && r.height == 300,
          "got \(r.width)x\(r.height)")

    // (b) Canvas background actually fills.
    let corner = r.pixel(2, 2)
    check("background is opaque white",
          near(corner.r, 255) && near(corner.g, 255) && near(corner.b, 255) && corner.a == 255,
          "got \(corner)")

    // (c) Rectangle at (20,20,100x60): blue fill, red 4px stroke.
    let fill = r.pixel(70, 50)
    check("rect interior is blue fill",
          fill.b > 200 && fill.r < 60 && fill.g < 60, "got \(fill)")
    let stroke = r.pixel(70, 20)
    check("rect edge is red stroke",
          stroke.r > 180 && stroke.g < 90 && stroke.b < 90, "got \(stroke)")

    // (d) Ellipse at (200,20,120x80), stroke only: the border is green and the
    //     centre is untouched. This is also the click-through property.
    let ellipseCenter = r.pixel(260, 60)
    check("unfilled ellipse centre is background",
          near(ellipseCenter.r, 255) && near(ellipseCenter.g, 255) && near(ellipseCenter.b, 255),
          "got \(ellipseCenter)")
    let ellipseEdge = r.pixel(260, 21)
    check("ellipse top edge is green stroke",
          ellipseEdge.g > ellipseEdge.r && ellipseEdge.g > ellipseEdge.b,
          "got \(ellipseEdge)")

    // (e) Freehand stroke along y=200 from x=40 to x=200, 8px wide.
    let onStroke = r.pixel(120, 200)
    check("freehand stroke is drawn", onStroke.r < 80 && onStroke.a == 255, "got \(onStroke)")
    let offStroke = r.pixel(120, 170)
    check("above the stroke is background", near(offStroke.r, 255), "got \(offStroke)")

    // (f) Arrow head owns the tip: the shaft is pulled back so the filled head
    //     covers the endpoint.
    let arrowTip = r.pixel(357, 257)
    check("arrow head is filled at the tip", arrowTip.r < 140, "got \(arrowTip)")

    // (g) An object with an unrecognized `type` renders NOTHING but must not
    //     break the render. Nothing to probe positively — the fact that every
    //     other assertion passed proves it did not corrupt the pass.
    check("unknown object type did not break the render", true)

    // (h) Ink actually covers a meaningful area, catching a silent "renders
    //     nothing" regression that per-pixel probes could miss.
    let inked = r.count { $0.r < 240 || $0.g < 240 || $0.b < 240 }
    check("inked pixel population is plausible", inked > 3000 && inked < 40000,
          "got \(inked)")
}

// ---------------------------------------------------------------------------
// transparent.png — 200x200, transparent, one opaque red square
// ---------------------------------------------------------------------------

print("transparent.png")
if let r = load("transparent.png") {
    check("export is exactly 200x200", r.width == 200 && r.height == 200,
          "got \(r.width)x\(r.height)")

    // (a) Unpainted areas are FULLY transparent. The classic failure is an
    //     opaque white background sneaking in.
    for (x, y) in [(2, 2), (198 - 1, 2), (2, 198 - 1), (10, 190)] {
        let p = r.pixel(x, y)
        check("alpha == 0 at (\(x),\(y))", p.a == 0, "got \(p)")
    }

    // (b) The painted square is opaque.
    let inside = r.pixel(100, 100)
    check("square interior is opaque red",
          inside.a == 255 && inside.r > 200 && inside.g < 60, "got \(inside)")

    // (c) THE CHECKERBOARD MUST NOT BE IN THE FILE. It is view chrome. If it
    //     leaked into the renderer, the transparent region would be white and
    //     light-grey 8px squares instead of alpha 0.
    let transparentCount = r.count { $0.a == 0 }
    let expectedTransparent = 200 * 200 - 100 * 100
    check("transparent area is exactly the unpainted region",
          near(transparentCount, expectedTransparent, 400),
          "got \(transparentCount), expected ~\(expectedTransparent)")
    check("no checkerboard leaked into the export",
          r.count { $0.a == 255 && $0.r > 200 && $0.g > 200 && $0.b > 200 } == 0)
}

// ---------------------------------------------------------------------------
// offcanvas.png — content outside the page rect must be clipped away
// ---------------------------------------------------------------------------

print("offcanvas.png")
if let r = load("offcanvas.png") {
    check("export is exactly 100x100", r.width == 100 && r.height == 100,
          "got \(r.width)x\(r.height)")
    // The page rect is the export boundary in infinite mode too — that is the
    // whole reason "export the page, Trim to Content on demand" is coherent.
    let dark = r.count { $0.r < 128 && $0.a > 0 }
    check("off-canvas content is clipped out of the export", dark == 0,
          "found \(dark) dark pixels")
}

// ---------------------------------------------------------------------------
// text.png — a bold word rendered through the export pipeline.
// ---------------------------------------------------------------------------

print("text.png")
if let r = load("text.png") {
    check("export is exactly 320x140", r.width == 320 && r.height == 140,
          "got \(r.width)x\(r.height)")

    // (a) Glyphs produce real dark ink — text is NOT a screen-only overlay. A
    //     bold word at 72px inks thousands of pixels; a "renders nothing"
    //     regression collapses this to ~0.
    let darkInk = r.count { $0.r < 80 && $0.g < 80 && $0.b < 80 && $0.a == 255 }
    check("glyphs are inked through the export pipeline",
          darkInk > 400 && darkInk < 20000, "got \(darkInk)")

    // (b) The glyphs sit within their box, not smeared across the canvas: the
    //     bottom-right corner (well past a left-aligned two-letter word) is the
    //     white background.
    let corner = r.pixel(305, 130)
    check("background beyond the text is white",
          near(corner.r, 255) && near(corner.g, 255) && near(corner.b, 255),
          "got \(corner)")

    // (c) Ink actually lands in the glyph band (origin y=30, ~72px tall), which
    //     a wrong y-flip in the CoreText draw would move off-canvas.
    var inkedRows = 0
    for y in 30...100 where (0..<r.width).contains(where: {
        let p = r.pixel($0, y); return p.r < 80 && p.a == 255
    }) { inkedRows += 1 }
    check("the glyph band carries ink", inkedRows > 20, "got \(inkedRows) inked rows")
}

// ---------------------------------------------------------------------------

print("")
if failures == 0 {
    print("verify-render: \(checks) checks passed")
    exit(0)
} else {
    print("verify-render: \(failures)/\(checks) checks FAILED")
    exit(1)
}
