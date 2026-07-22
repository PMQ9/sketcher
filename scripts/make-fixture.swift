#!/usr/bin/env swift
// Writes the scene fixtures that verify-render.sh renders and asserts against.
//
// The fixture is designed BACKWARDS from the assertions: every shape sits at a
// coordinate the checker probes by name, so a failure points at one shape
// rather than "the image changed".
//
// Usage: swift scripts/make-fixture.swift <output-dir>

import Foundation

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory()

func write(_ name: String, _ json: String) {
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    do {
        try json.write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(url.path)")
    } catch {
        FileHandle.standardError.write(Data("error writing \(name): \(error)\n".utf8))
        exit(1)
    }
}

// ---------------------------------------------------------------------------
// shapes.json — an opaque white canvas with one of every drawable kind.
//
// Canvas is 400x300 at pixelsPerPoint 1, so canvas pixels == asserted pixels
// and the probe coordinates in verify-render.swift are readable by hand.
// ---------------------------------------------------------------------------

let shapes = """
{
  "formatVersion": 1,
  "minimumReaderVersion": 1,
  "canvasGeneration": 0,
  "activeLayerID": "11111111-1111-1111-1111-111111111111",
  "guides": [],
  "canvas": {
    "pixelSize": {"width": 400, "height": 300},
    "pixelsPerPoint": 1,
    "colorSpaceName": "kCGColorSpaceSRGB",
    "mode": "contained",
    "background": {"kind": "solid", "color": {"r": 1, "g": 1, "b": 1, "a": 1}}
  },
  "layers": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Layer 1",
      "isVisible": true,
      "isLocked": false,
      "opacity": 1,
      "blendMode": "normal",
      "objects": [
        {
          "id": "aaaaaaaa-0000-0000-0000-000000000001",
          "type": "rectangle",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "strokeColor": {"r": 1, "g": 0, "b": 0, "a": 1},
            "fillColor": {"r": 0, "g": 0, "b": 1, "a": 1},
            "strokeWidthPx": 4, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": true
          },
          "payload": {"rect": {"x": 20, "y": 20, "width": 100, "height": 60}, "cornerRadius": 0}
        },
        {
          "id": "aaaaaaaa-0000-0000-0000-000000000002",
          "type": "ellipse",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "strokeColor": {"r": 0, "g": 0.5, "b": 0, "a": 1},
            "strokeWidthPx": 6, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": true
          },
          "payload": {"rect": {"x": 200, "y": 20, "width": 120, "height": 80}, "cornerRadius": 0}
        },
        {
          "id": "aaaaaaaa-0000-0000-0000-000000000003",
          "type": "stroke",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "strokeColor": {"r": 0, "g": 0, "b": 0, "a": 1},
            "strokeWidthPx": 8, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": true
          },
          "payload": {
            "brush": {"engine": "pen", "sizePx": 8, "thinning": 0.5, "smoothing": 0.5,
                      "streamline": 0.5, "simulatePressure": true, "nibAngle": 0.785},
            "samples": [
              {"x": 40, "y": 200},
              {"x": 120, "y": 200},
              {"x": 200, "y": 200}
            ]
          }
        },
        {
          "id": "aaaaaaaa-0000-0000-0000-000000000004",
          "type": "arrow",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "strokeColor": {"r": 0, "g": 0, "b": 0, "a": 1},
            "strokeWidthPx": 4, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": true
          },
          "payload": {
            "start": {"x": 260, "y": 180}, "end": {"x": 360, "y": 260},
            "startHead": "none", "endHead": "arrow"
          }
        },
        {
          "id": "aaaaaaaa-0000-0000-0000-000000000005",
          "type": "hyperbolicSpline",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "strokeWidthPx": 6, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": true
          },
          "payload": {"curvature": 3.5, "knots": [1, 2, 3], "label": "from-the-future"}
        }
      ]
    }
  ]
}
"""

// ---------------------------------------------------------------------------
// transparent.json — a transparent canvas with ONE opaque square.
//
// Exists to assert alpha == 0 everywhere the user did not paint, and that the
// view-only checkerboard never reaches an exported file.
// ---------------------------------------------------------------------------

let transparent = """
{
  "formatVersion": 1,
  "minimumReaderVersion": 1,
  "canvasGeneration": 0,
  "activeLayerID": "22222222-2222-2222-2222-222222222222",
  "guides": [],
  "canvas": {
    "pixelSize": {"width": 200, "height": 200},
    "pixelsPerPoint": 1,
    "colorSpaceName": "kCGColorSpaceSRGB",
    "mode": "contained",
    "background": {"kind": "transparent"}
  },
  "layers": [
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "name": "Layer 1",
      "isVisible": true,
      "isLocked": false,
      "opacity": 1,
      "blendMode": "normal",
      "objects": [
        {
          "id": "bbbbbbbb-0000-0000-0000-000000000001",
          "type": "rectangle",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "fillColor": {"r": 1, "g": 0, "b": 0, "a": 1},
            "strokeWidthPx": 0, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": false
          },
          "payload": {"rect": {"x": 50, "y": 50, "width": 100, "height": 100}, "cornerRadius": 0}
        }
      ]
    }
  ]
}
"""

// ---------------------------------------------------------------------------
// offcanvas.json — one shape entirely outside the page rect.
//
// The page rect is the export boundary in BOTH canvas modes, so this must not
// appear in the output at all.
// ---------------------------------------------------------------------------

let offcanvas = """
{
  "formatVersion": 1,
  "minimumReaderVersion": 1,
  "canvasGeneration": 0,
  "activeLayerID": "33333333-3333-3333-3333-333333333333",
  "guides": [],
  "canvas": {
    "pixelSize": {"width": 100, "height": 100},
    "pixelsPerPoint": 1,
    "colorSpaceName": "kCGColorSpaceSRGB",
    "mode": "infinite",
    "background": {"kind": "solid", "color": {"r": 1, "g": 1, "b": 1, "a": 1}}
  },
  "layers": [
    {
      "id": "33333333-3333-3333-3333-333333333333",
      "name": "Layer 1",
      "isVisible": true,
      "isLocked": false,
      "opacity": 1,
      "blendMode": "normal",
      "objects": [
        {
          "id": "cccccccc-0000-0000-0000-000000000001",
          "type": "rectangle",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "fillColor": {"r": 0, "g": 0, "b": 0, "a": 1},
            "strokeWidthPx": 0, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": false
          },
          "payload": {"rect": {"x": 500, "y": 500, "width": 50, "height": 50}, "cornerRadius": 0}
        }
      ]
    }
  ]
}
"""

// ---------------------------------------------------------------------------
// text.json — a white canvas with one bold text object.
//
// Proves text renders through the SAME export pipeline as every other kind
// (the single-renderer invariant) rather than through some screen-only path:
// the glyphs must produce real dark pixels in the exported PNG, and the empty
// region to the right of the word must stay white.
// ---------------------------------------------------------------------------

let text = """
{
  "formatVersion": 1,
  "minimumReaderVersion": 1,
  "canvasGeneration": 0,
  "activeLayerID": "44444444-4444-4444-4444-444444444444",
  "guides": [],
  "canvas": {
    "pixelSize": {"width": 320, "height": 140},
    "pixelsPerPoint": 1,
    "colorSpaceName": "kCGColorSpaceSRGB",
    "mode": "contained",
    "background": {"kind": "solid", "color": {"r": 1, "g": 1, "b": 1, "a": 1}}
  },
  "layers": [
    {
      "id": "44444444-4444-4444-4444-444444444444",
      "name": "Layer 1",
      "isVisible": true,
      "isLocked": false,
      "opacity": 1,
      "blendMode": "normal",
      "objects": [
        {
          "id": "dddddddd-0000-0000-0000-000000000001",
          "type": "text",
          "rotation": 0,
          "isLocked": false,
          "isHidden": false,
          "groupIDs": [],
          "style": {
            "strokeColor": {"r": 0, "g": 0, "b": 0, "a": 1},
            "strokeWidthPx": 0, "dash": "solid", "lineCap": 1, "lineJoin": 1,
            "opacity": 1, "blendMode": "normal", "antialias": true
          },
          "payload": {
            "string": "Hi", "origin": {"x": 20, "y": 30}, "resize": "autoWidth",
            "fontName": "Helvetica Neue", "fontSizePx": 72,
            "isBold": true, "isItalic": false, "isUnderlined": false,
            "alignment": "left", "lineHeightMultiple": 1
          }
        }
      ]
    }
  ]
}
"""

write("shapes.json", shapes)
write("transparent.json", transparent)
write("offcanvas.json", offcanvas)
write("text.json", text)
