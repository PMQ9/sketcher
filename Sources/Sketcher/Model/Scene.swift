import CoreGraphics
import Foundation

/// The saved, undoable content — and nothing else.
///
/// INVARIANT: no selection, no active tool, no viewport transform, no
/// interaction state ever lives here. Those are view-model state and are never
/// snapshotted. `Scene` is a value type, and `Scene ==` is what
/// `endGesture()`'s push-only-if-changed check depends on.
struct Scene: Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int = Scene.currentFormatVersion
    var canvas: CanvasSpec
    /// Bottom -> top. Array order IS z-order.
    var layers: [Layer]
    var activeLayerID: Layer.ID
    var guides: [Guide] = []
    /// Bumped by crop / canvas-size / image-size. Every render and filter cache
    /// keys on it, so stale patches can never survive a canvas change.
    var canvasGeneration: Int = 0

    init(canvas: CanvasSpec) {
        let first = Layer.vector(named: "Layer 1")
        self.canvas = canvas
        self.layers = [first]
        self.activeLayerID = first.id
    }

    /// A blank document at the default size, inked to suit its background.
    static func blank(background: CanvasBackground = .light,
                      pixelSize: PixelSize = CanvasSpec.defaultPixelSize) -> Scene {
        Scene(canvas: CanvasSpec(pixelSize: pixelSize, background: background))
    }

    // MARK: - Layer access

    var activeLayerIndex: Int? {
        layers.firstIndex { $0.id == activeLayerID }
    }

    var activeLayer: Layer? {
        activeLayerIndex.map { layers[$0] }
    }

    func layer(with id: Layer.ID) -> Layer? {
        layers.first { $0.id == id }
    }

    func index(of id: Layer.ID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    /// Mutate a layer in place. No-op if the id is unknown, so callers never
    /// have to guard against a layer deleted mid-gesture.
    mutating func withLayer(_ id: Layer.ID, _ body: (inout Layer) -> Void) {
        guard let i = index(of: id) else { return }
        body(&layers[i])
    }

    // MARK: - Object access

    /// Every object across every layer, bottom -> top. Z-order is layer order
    /// first, then object order within the layer.
    var allObjects: [DrawObject] {
        layers.flatMap(\.objects)
    }

    func object(with id: UUID) -> DrawObject? {
        for layer in layers {
            if let found = layer.objects.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    func layerID(containing objectID: UUID) -> Layer.ID? {
        layers.first { $0.objects.contains { $0.id == objectID } }?.id
    }

    mutating func withObject(_ id: UUID, _ body: (inout DrawObject) -> Void) {
        for li in layers.indices {
            guard case .vector(var objs) = layers[li].content else { continue }
            guard let oi = objs.firstIndex(where: { $0.id == id }) else { continue }
            body(&objs[oi])
            layers[li].content = .vector(objs)
            return
        }
    }

    /// Append to the active layer if it is a vector layer, else to the nearest
    /// vector layer above it — creating one when none exists. Never silent:
    /// the caller names the resulting undo step.
    @discardableResult
    mutating func addObject(_ object: DrawObject) -> Layer.ID {
        if let i = activeLayerIndex, layers[i].isVector, layers[i].isEditable {
            layers[i].objects.append(object)
            return layers[i].id
        }
        let start = activeLayerIndex.map { $0 + 1 } ?? layers.count
        if let above = layers[start...].firstIndex(where: { $0.isVector && $0.isEditable }) {
            layers[above].objects.append(object)
            return layers[above].id
        }
        var fresh = Layer.vector(named: "Layer \(layers.count + 1)")
        fresh.objects.append(object)
        layers.append(fresh)
        activeLayerID = fresh.id
        return fresh.id
    }

    mutating func removeObjects(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for li in layers.indices {
            guard case .vector(var objs) = layers[li].content else { continue }
            let before = objs.count
            objs.removeAll { ids.contains($0.id) }
            if objs.count != before { layers[li].content = .vector(objs) }
        }
    }

    /// Union of every object's render bounds — what `Trim to Content` snaps to.
    var contentBounds: CGRect {
        allObjects.reduce(CGRect.null) { $0.unionIgnoringNull($1.renderBounds) }
    }
}

// MARK: - Canvas

struct CanvasSpec: Equatable, Sendable, Codable {
    /// Integer pixels, authoritative. NOT points — this is the one unit below
    /// the view layer.
    var pixelSize: PixelSize
    /// Display density hint. Converts point-denominated UI presets into pixels
    /// and stamps PNG DPI on export. Does not affect stored geometry.
    var pixelsPerPoint: CGFloat = 2.0
    var background: CanvasBackground
    var mode: CanvasMode = .contained
    /// Chosen ONCE at creation — a blank canvas has no source image to inherit
    /// from. Threaded through every CGContext, the CIContext output, the
    /// eyedropper readback, and PNG export.
    var colorSpaceName: String = CGColorSpace.sRGB as String

    static let maxSide = 16_384
    static let maxPixels = 80_000_000
    static let defaultPixelSize = PixelSize(width: 2560, height: 1600)

    init(pixelSize: PixelSize = CanvasSpec.defaultPixelSize,
         pixelsPerPoint: CGFloat = 2.0,
         background: CanvasBackground = .light,
         mode: CanvasMode = .contained) {
        self.pixelSize = pixelSize
        self.pixelsPerPoint = pixelsPerPoint
        self.background = background
        self.mode = mode
    }

    var cgColorSpace: CGColorSpace {
        CGColorSpace(name: colorSpaceName as CFString) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// The page rect — the export boundary in BOTH canvas modes.
    var pageRect: CGRect { pixelSize.rect }

    /// Convert a point-denominated UI preset (stroke width, font size) into the
    /// pixel space the model stores. The only place this multiplication is
    /// allowed outside CanvasTransform.
    func px(fromPoints points: CGFloat) -> CGFloat { points * pixelsPerPoint }
}

/// Contained: the page rect clips content and bounds export; its edges are
/// draggable to extend the canvas.
/// Infinite: pan/zoom is unclamped and content outside the page is kept and
/// drawn. The page rect still exists and is still the export boundary.
enum CanvasMode: String, Equatable, Sendable, Codable {
    case contained, infinite

    var clipsToPage: Bool { self == .contained }
}

struct PixelSize: Equatable, Hashable, Sendable, Codable {
    var width: Int
    var height: Int

    var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    var cgSize: CGSize { CGSize(width: width, height: height) }
    var pixelCount: Int { width * height }

    /// Bytes for one RGBA8 raster layer at this size.
    var rasterByteCount: Int { pixelCount * PixelFormat.bytesPerPixel }

    var isValid: Bool {
        width > 0 && height > 0
            && width <= CanvasSpec.maxSide && height <= CanvasSpec.maxSide
            && pixelCount <= CanvasSpec.maxPixels
    }
}

enum CanvasBackground: Equatable, Sendable, Codable {
    case transparent
    case solid(RGBAColor)

    static let light = CanvasBackground.solid(RGBAColor(r: 1, g: 1, b: 1))
    static let dark = CanvasBackground.solid(RGBAColor(r: 0.11, g: 0.11, b: 0.12))

    // Hand-written rather than synthesized: the synthesized form for an enum
    // with associated values is `{"solid":{"_0":{…}}}`, and `_0` is a compiler
    // artifact that would be baked into the file format forever.
    private enum CodingKeys: String, CodingKey { case kind, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "solid"
        if kind == "transparent" {
            self = .transparent
        } else {
            let color = try c.decodeIfPresent(RGBAColor.self, forKey: .color)
            self = .solid(color ?? RGBAColor(r: 1, g: 1, b: 1))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transparent:
            try c.encode("transparent", forKey: .kind)
        case .solid(let color):
            try c.encode("solid", forKey: .kind)
            try c.encode(color, forKey: .color)
        }
    }

    /// Ink that will be visible against this background. Evaluated ONCE at
    /// canvas creation and written into the style defaults — never recomputed
    /// live, which would fight the user's manual color choices. Without this,
    /// the first stroke on a dark canvas is black-on-black and the app looks
    /// broken.
    var defaultInk: RGBAColor {
        switch self {
        case .transparent: return .black
        case .solid(let c): return c.luminance < 0.5 ? .white : .black
        }
    }

    var isTransparent: Bool {
        if case .transparent = self { return true }
        return false
    }

    var solidColor: RGBAColor? {
        if case .solid(let c) = self { return c }
        return nil
    }
}

struct Guide: Equatable, Identifiable, Sendable, Codable {
    enum Axis: String, Sendable, Codable { case horizontal, vertical }
    let id: UUID
    var axis: Axis
    /// Canvas pixels along the perpendicular axis.
    var position: CGFloat

    init(id: UUID = UUID(), axis: Axis, position: CGFloat) {
        self.id = id
        self.axis = axis
        self.position = position
    }
}
