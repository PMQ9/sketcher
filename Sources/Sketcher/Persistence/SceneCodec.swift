import CoreGraphics
import Foundation

/// JSON encoding of a `Scene`.
///
/// Two forward-compatibility mechanisms, both mandatory from v1:
///
/// 1. **Additive fields decode with defaults.** Every property uses
///    `decodeIfPresent ?? default`, so adding a field never bumps
///    `formatVersion`.
/// 2. **Unknown objects round-trip verbatim.** An object whose `type` string
///    this build does not recognize keeps its payload as an opaque
///    `JSONValue`, renders as nothing, and re-encodes byte-identically. This
///    is the mechanism everyone skips and regrets.
///
/// M8 wraps this in the `.sketcher` file package with content-addressed raster
/// surfaces; the manifest shape below is already that format's `Info.json`.
/// `nonisolated` on purpose: the package sets `.defaultIsolation(MainActor)`,
/// but encoding and decoding are pure data transforms that `NSDocument` may
/// call off the main actor, and PNG-encoding a large layer on main would hitch
/// every autosave.
enum SceneCodec {
    static func encode(_ scene: Scene) throws -> Data {
        let encoder = JSONEncoder()
        // Deterministic output so `--test-roundtrip` can diff byte-for-byte.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(SceneFile(scene))
    }

    static func decode(_ data: Data) throws -> Scene {
        let file = try JSONDecoder().decode(SceneFile.self, from: data)
        guard file.minimumReaderVersion <= SceneFile.currentVersion else {
            throw CodecError.tooNew(file.minimumReaderVersion)
        }
        return file.makeScene()
    }

    enum CodecError: LocalizedError {
        case tooNew(Int)

        var errorDescription: String? {
            switch self {
            case .tooNew(let version):
                return "This document needs a newer version of Sketcher (format \(version))."
            }
        }
    }
}

// MARK: - Manifest

struct SceneFile: Codable {
    static let currentVersion = 1

    /// Bumped ONLY on a breaking change. Additive fields never bump it.
    var formatVersion: Int
    /// Refuse to open when this exceeds our version — lets a future writer mark
    /// a file unreadable by old builds without those builds having to guess.
    var minimumReaderVersion: Int
    var canvas: CanvasSpec
    var layers: [LayerSpec]
    var guides: [Guide]
    var activeLayerID: UUID
    var canvasGeneration: Int

    init(_ scene: Scene) {
        self.formatVersion = SceneFile.currentVersion
        self.minimumReaderVersion = 1
        self.canvas = scene.canvas
        self.layers = scene.layers.map(LayerSpec.init)
        self.guides = scene.guides
        self.activeLayerID = scene.activeLayerID
        self.canvasGeneration = scene.canvasGeneration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        minimumReaderVersion = try c.decodeIfPresent(Int.self, forKey: .minimumReaderVersion) ?? 1
        canvas = try c.decode(CanvasSpec.self, forKey: .canvas)
        layers = try c.decodeIfPresent([LayerSpec].self, forKey: .layers) ?? []
        guides = try c.decodeIfPresent([Guide].self, forKey: .guides) ?? []
        activeLayerID = try c.decodeIfPresent(UUID.self, forKey: .activeLayerID) ?? UUID()
        canvasGeneration = try c.decodeIfPresent(Int.self, forKey: .canvasGeneration) ?? 0
    }

    func makeScene() -> Scene {
        var scene = Scene(canvas: canvas)
        let decoded = layers.map(\.layer)
        scene.layers = decoded.isEmpty ? [Layer.vector(named: "Layer 1")] : decoded
        scene.guides = guides
        scene.canvasGeneration = canvasGeneration
        scene.activeLayerID = scene.layers.contains { $0.id == activeLayerID }
            ? activeLayerID
            : (scene.layers.first?.id ?? UUID())
        return scene
    }
}

struct LayerSpec: Codable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var isLocked: Bool
    var opacity: Double
    /// Stringly-typed on purpose: an unknown blend mode falls back to `.normal`
    /// for rendering but survives the round-trip byte-identically.
    var blendMode: String
    var objects: [ObjectSpec]
    /// "surfaces/<sha256>.png" once raster layers exist (M6/M8).
    var rasterFile: String?

    init(_ layer: Layer) {
        id = layer.id
        name = layer.name
        isVisible = layer.isVisible
        isLocked = layer.isLocked
        opacity = Double(layer.opacity)
        blendMode = BlendModeNames.name(for: layer.blend)
        switch layer.content {
        case .vector(let objects):
            self.objects = objects.map(ObjectSpec.init)
            self.rasterFile = nil
        case .raster:
            self.objects = []
            self.rasterFile = nil   // written by PackageIO at M8
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        blendMode = try c.decodeIfPresent(String.self, forKey: .blendMode) ?? "normal"
        objects = try c.decodeIfPresent([ObjectSpec].self, forKey: .objects) ?? []
        rasterFile = try c.decodeIfPresent(String.self, forKey: .rasterFile)
    }

    var layer: Layer {
        var result = Layer(id: id, name: name, content: .vector(objects.map(\.object)))
        result.isVisible = isVisible
        result.isLocked = isLocked
        result.opacity = CGFloat(opacity)
        result.blend = BlendModeNames.mode(for: blendMode)
        return result
    }
}

struct ObjectSpec: Codable {
    var id: UUID
    /// "rectangle" | "ellipse" | "stroke" | … An UNRECOGNIZED value keeps
    /// `payload` verbatim and re-encodes it unchanged.
    var type: String
    var rotation: CGFloat
    var isLocked: Bool
    var isHidden: Bool
    var groupIDs: [UUID]
    var style: StyleSpec
    var erasedGeometry: PathGeometry?
    var payload: JSONValue

    init(_ object: DrawObject) {
        id = object.id
        type = object.kind.typeName
        rotation = object.rotation
        isLocked = object.isLocked
        isHidden = object.isHidden
        groupIDs = object.groupIDs
        style = StyleSpec(object.style)
        erasedGeometry = object.erasedGeometry
        payload = object.unknownPayload ?? KindCodec.payload(for: object.kind)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        groupIDs = try c.decodeIfPresent([UUID].self, forKey: .groupIDs) ?? []
        style = try c.decodeIfPresent(StyleSpec.self, forKey: .style) ?? StyleSpec()
        erasedGeometry = try c.decodeIfPresent(PathGeometry.self, forKey: .erasedGeometry)
        payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null
    }

    var object: DrawObject {
        var result: DrawObject
        if let kind = KindCodec.kind(type: type, payload: payload) {
            result = DrawObject(id: id, kind: kind, style: style.style, rotation: rotation)
        } else {
            // Unknown type: keep the payload so saving does not lose it.
            result = DrawObject(id: id, kind: .unknown(type: type),
                                style: style.style, rotation: rotation)
            result.unknownPayload = payload
        }
        result.isLocked = isLocked
        result.isHidden = isHidden
        result.groupIDs = groupIDs
        result.erasedGeometry = erasedGeometry
        return result
    }
}

struct StyleSpec: Codable {
    var strokeColor: RGBAColor?
    var fillColor: RGBAColor?
    var strokeWidthPx: CGFloat = 6
    var dash: DashStyle = .solid
    var lineCap: Int = Int(CGLineCap.round.rawValue)
    var lineJoin: Int = Int(CGLineJoin.round.rawValue)
    var opacity: CGFloat = 1
    var blendMode: String = "normal"
    var antialias: Bool = true
    var shadowOffset: CGSize?
    var shadowBlurPx: CGFloat?
    var shadowColor: RGBAColor?

    init() {}

    init(_ style: ObjectStyle) {
        strokeColor = style.strokeColor
        fillColor = style.fill.color
        strokeWidthPx = style.strokeWidthPx
        dash = style.dash
        lineCap = Int(style.lineCap.rawValue)
        lineJoin = Int(style.lineJoin.rawValue)
        opacity = style.opacity
        blendMode = BlendModeNames.name(for: style.blend)
        antialias = style.antialias
        shadowOffset = style.shadow?.offset
        shadowBlurPx = style.shadow?.blurRadiusPx
        shadowColor = style.shadow?.color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try c.decodeIfPresent(RGBAColor.self, forKey: .strokeColor)
        fillColor = try c.decodeIfPresent(RGBAColor.self, forKey: .fillColor)
        strokeWidthPx = try c.decodeIfPresent(CGFloat.self, forKey: .strokeWidthPx) ?? 6
        dash = try c.decodeIfPresent(DashStyle.self, forKey: .dash) ?? .solid
        lineCap = try c.decodeIfPresent(Int.self, forKey: .lineCap)
            ?? Int(CGLineCap.round.rawValue)
        lineJoin = try c.decodeIfPresent(Int.self, forKey: .lineJoin)
            ?? Int(CGLineJoin.round.rawValue)
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1
        blendMode = try c.decodeIfPresent(String.self, forKey: .blendMode) ?? "normal"
        antialias = try c.decodeIfPresent(Bool.self, forKey: .antialias) ?? true
        shadowOffset = try c.decodeIfPresent(CGSize.self, forKey: .shadowOffset)
        shadowBlurPx = try c.decodeIfPresent(CGFloat.self, forKey: .shadowBlurPx)
        shadowColor = try c.decodeIfPresent(RGBAColor.self, forKey: .shadowColor)
    }

    var style: ObjectStyle {
        var result = ObjectStyle()
        result.strokeColor = strokeColor
        result.fill = fillColor.map { Fill.solid($0) } ?? .none
        result.strokeWidthPx = strokeWidthPx
        result.dash = dash
        result.lineCap = CGLineCap(rawValue: Int32(lineCap)) ?? .round
        result.lineJoin = CGLineJoin(rawValue: Int32(lineJoin)) ?? .round
        result.opacity = opacity
        result.blend = BlendModeNames.mode(for: blendMode)
        result.antialias = antialias
        if let offset = shadowOffset, let blur = shadowBlurPx, let color = shadowColor {
            result.shadow = ShadowSpec(offset: offset, blurRadiusPx: blur, color: color)
        }
        return result
    }
}

/// Blend modes are stored by NAME, not by raw value: raw values are a
/// CoreGraphics implementation detail, and a name survives an SDK change and
/// stays readable in a diff.
enum BlendModeNames {
    private static let table: [(String, CGBlendMode)] = [
        ("normal", .normal), ("multiply", .multiply), ("screen", .screen),
        ("overlay", .overlay), ("darken", .darken), ("lighten", .lighten),
        ("colorDodge", .colorDodge), ("colorBurn", .colorBurn),
        ("softLight", .softLight), ("hardLight", .hardLight),
        ("difference", .difference), ("exclusion", .exclusion),
        ("hue", .hue), ("saturation", .saturation), ("color", .color),
        ("luminosity", .luminosity), ("destinationOut", .destinationOut)
    ]

    static func name(for mode: CGBlendMode) -> String {
        table.first { $0.1 == mode }?.0 ?? "normal"
    }

    static func mode(for name: String) -> CGBlendMode {
        table.first { $0.0 == name }?.1 ?? .normal
    }
}
