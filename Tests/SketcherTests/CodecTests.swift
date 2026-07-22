import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

@Suite("Codec")
struct CodecTests {

    private func populatedScene() -> Scene {
        var scene = Scene.blank(background: .dark)
        scene.canvas.mode = .infinite

        var style = ObjectStyle(strokeColor: .red, strokeWidthPx: 8)
        style.fill = .solid(.blue)
        style.dash = .dashed
        style.opacity = 0.8

        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 10, y: 20, width: 100, height: 50),
                             cornerRadius: 6),
            style: style, rotation: 0.4))
        scene.addObject(DrawObject(
            kind: .ellipse(rect: CGRect(x: 5, y: 5, width: 40, height: 40)),
            style: ObjectStyle()))
        scene.addObject(DrawObject(
            kind: .arrow(ArrowPayload(start: CGPoint(x: 0, y: 0),
                                      end: CGPoint(x: 90, y: 90),
                                      startHead: .dot, endHead: .triangle)),
            style: ObjectStyle()))
        scene.addObject(DrawObject(
            kind: .stroke(StrokePayload(samples: [
                StrokeSample(point: CGPoint(x: 1, y: 2), pressure: 0.4),
                StrokeSample(point: CGPoint(x: 8, y: 9), pressure: 0.9)
            ])),
            style: ObjectStyle()))
        scene.guides.append(Guide(axis: .vertical, position: 128))
        return scene
    }

    @Test("A populated scene round-trips through encode/decode")
    func sceneRoundTrips() throws {
        let original = populatedScene()
        let decoded = try SceneCodec.decode(SceneCodec.encode(original))

        #expect(decoded.canvas.pixelSize == original.canvas.pixelSize)
        #expect(decoded.canvas.mode == .infinite)
        #expect(decoded.canvas.background == .dark)
        #expect(decoded.guides.count == 1)
        #expect(decoded.allObjects.count == original.allObjects.count)
        #expect(decoded.activeLayerID == original.activeLayerID)
    }

    @Test("Encoding is deterministic, so round-trip diffs are meaningful")
    func encodingIsDeterministic() throws {
        let scene = populatedScene()
        #expect(try SceneCodec.encode(scene) == SceneCodec.encode(scene))

        // And re-encoding after a decode must be byte-identical.
        let once = try SceneCodec.encode(scene)
        let twice = try SceneCodec.encode(SceneCodec.decode(once))
        #expect(once == twice)
    }

    @Test("Object geometry and style survive the round trip exactly")
    func objectFidelity() throws {
        let original = populatedScene()
        let decoded = try SceneCodec.decode(SceneCodec.encode(original))

        guard let before = original.allObjects.first,
              let after = decoded.allObjects.first(where: { $0.id == before.id }) else {
            Issue.record("object went missing")
            return
        }
        #expect(after.kind == before.kind)
        #expect(after.rotation == before.rotation)
        #expect(after.style.strokeColor == before.style.strokeColor)
        #expect(after.style.fill == before.style.fill)
        #expect(after.style.dash == before.style.dash)
        #expect(after.style.strokeWidthPx == before.style.strokeWidthPx)
    }

    @Test("Pressure per sample survives, so strokes stay re-renderable")
    func strokePressureSurvives() throws {
        let original = populatedScene()
        let decoded = try SceneCodec.decode(SceneCodec.encode(original))

        let strokes = decoded.allObjects.compactMap { object -> StrokePayload? in
            if case .stroke(let payload) = object.kind { return payload }
            return nil
        }
        #expect(strokes.count == 1)
        #expect(strokes.first?.samples.map(\.pressure) == [0.4, 0.9])
    }

    // MARK: - Forward compatibility

    @Test("An object with an unknown type round-trips byte-identically")
    func unknownObjectSurvivesRoundTrip() throws {
        // The mechanism everyone skips and regrets: a file written by a newer
        // build must not silently lose objects when opened and re-saved here.
        var scene = Scene.blank()
        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                             cornerRadius: 0),
            style: ObjectStyle()))

        var json = try JSONSerialization.jsonObject(
            with: SceneCodec.encode(scene)) as! [String: Any]
        var layers = json["layers"] as! [[String: Any]]
        var objects = layers[0]["objects"] as! [[String: Any]]

        // Simulate a future object kind with a payload this build cannot parse.
        objects.append([
            "id": UUID().uuidString,
            "type": "hyperbolicSpline",
            "rotation": 0.25,
            "isLocked": false,
            "isHidden": false,
            "groupIDs": [],
            "style": ["strokeWidthPx": 6, "opacity": 1, "antialias": true,
                      "blendMode": "normal", "dash": "solid",
                      "lineCap": 1, "lineJoin": 1],
            "payload": ["curvature": 3.5, "knots": [1, 2, 3], "label": "future"]
        ])
        layers[0]["objects"] = objects
        json["layers"] = layers

        let futureData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try SceneCodec.decode(futureData)

        // It decodes as .unknown, renders as nothing, hit-tests to nothing…
        let unknown = decoded.allObjects.first { $0.kind.typeName == "hyperbolicSpline" }
        #expect(unknown != nil)
        #expect(unknown?.hitTest(CGPoint(x: 0, y: 0), tolerance: 100) == false)
        #expect(decoded.allObjects.count == 2)

        // …and its payload comes back out intact on save.
        let reEncoded = try SceneCodec.encode(decoded)
        let reJSON = try JSONSerialization.jsonObject(with: reEncoded) as! [String: Any]
        let reLayers = reJSON["layers"] as! [[String: Any]]
        let reObjects = reLayers[0]["objects"] as! [[String: Any]]
        let survivor = reObjects.first { $0["type"] as? String == "hyperbolicSpline" }
        let payload = survivor?["payload"] as? [String: Any]

        #expect(payload?["curvature"] as? Double == 3.5)
        #expect(payload?["label"] as? String == "future")
        #expect((payload?["knots"] as? [Any])?.count == 3)
    }

    @Test("Missing optional fields decode to defaults without a version bump")
    func additiveFieldsDecodeWithDefaults() throws {
        // A minimal document from an older writer: only what it knew about.
        let minimal = """
        {
          "canvas": {
            "pixelSize": {"width": 800, "height": 600},
            "background": {"kind": "solid", "color": {"r": 1, "g": 1, "b": 1, "a": 1}},
            "pixelsPerPoint": 2,
            "colorSpaceName": "kCGColorSpaceSRGB",
            "mode": "contained"
          }
        }
        """.data(using: .utf8)!

        let scene = try SceneCodec.decode(minimal)
        #expect(scene.canvas.pixelSize == PixelSize(width: 800, height: 600))
        #expect(scene.guides.isEmpty)
        #expect(scene.canvasGeneration == 0)
        // A document with no layers still opens usable rather than empty.
        #expect(scene.layers.count == 1)
        #expect(scene.activeLayerID == scene.layers[0].id)
    }

    @Test("A file needing a newer reader is refused rather than half-read")
    func futureFormatIsRefused() throws {
        var scene = Scene.blank()
        scene.canvas.pixelSize = PixelSize(width: 100, height: 100)
        var json = try JSONSerialization.jsonObject(
            with: SceneCodec.encode(scene)) as! [String: Any]
        json["minimumReaderVersion"] = 99

        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: SceneCodec.CodecError.self) {
            try SceneCodec.decode(data)
        }
    }

    @Test("An unknown blend mode falls back to normal but survives the round trip")
    func unknownBlendModeFallsBack() {
        #expect(BlendModeNames.mode(for: "someFutureBlend") == .normal)
        #expect(BlendModeNames.name(for: .multiply) == "multiply")
        #expect(BlendModeNames.mode(for: BlendModeNames.name(for: .colorBurn)) == .colorBurn)
    }
}
