import CoreGraphics
import Foundation

// All object geometry is in CANVAS PIXELS, top-left origin, y-down.
// The view layer converts through CanvasTransform at the event boundary;
// nothing below this line knows about points, screen scale, or zoom.

struct DrawObject: Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: ObjectKind
    var style: ObjectStyle
    /// Rotation about the shape's bbox center, in radians. Applied only to
    /// rotatable kinds; ignored otherwise.
    var rotation: CGFloat = 0
    var isLocked = false
    var isHidden = false
    /// Excalidraw's model: a flat array of group ids, outermost first. No
    /// recursive scene graph, so Scene stays a flat value type.
    var groupIDs: [UUID] = []
    /// Partial vector erase AND redaction clipping. Accumulated via
    /// CGPath.subtracting — NOT an even-odd clip, which un-erases wherever
    /// two eraser strokes overlap.
    var erasedGeometry: PathGeometry? = nil
    /// Forward compatibility: an object whose `type` string this build does not
    /// recognize round-trips byte-identically instead of being dropped.
    var unknownPayload: JSONValue? = nil

    init(id: UUID = UUID(), kind: ObjectKind, style: ObjectStyle,
         rotation: CGFloat = 0) {
        self.id = id
        self.kind = kind
        self.style = style
        self.rotation = rotation
    }
}

enum ObjectKind: Equatable, Sendable {
    // shapes
    case rectangle(rect: CGRect, cornerRadius: CGFloat)
    case ellipse(rect: CGRect)
    case polygon(rect: CGRect, sides: Int, starInnerRatio: CGFloat?)
    case line(start: CGPoint, end: CGPoint, control: CGPoint?)
    case polyline(points: [CGPoint], closed: Bool)
    case arrow(ArrowPayload)
    // freehand
    case stroke(StrokePayload)
    // text
    case text(TextPayload)
    // raster placed as an object (imported, pasted, dropped floating selection)
    case image(RasterPayload)
    // non-destructive effect sampling the composite below it
    case filter(FilterPayload)
    /// Forward compat: renders nothing, hit-tests to nothing, re-encodes verbatim.
    case unknown(type: String)

    /// Stable discriminator used by the persistence layer and by the inspector's
    /// capability lookup.
    var typeName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .polygon: return "polygon"
        case .line: return "line"
        case .polyline: return "polyline"
        case .arrow: return "arrow"
        case .stroke: return "stroke"
        case .text: return "text"
        case .image: return "image"
        case .filter: return "filter"
        case .unknown(let t): return t
        }
    }
}

// MARK: - Payloads

struct ArrowPayload: Equatable, Sendable, Codable {
    var start: CGPoint
    var end: CGPoint
    var control: CGPoint? = nil
    var startHead: ArrowHead = .none
    var endHead: ArrowHead = .arrow

    // Explicit: supplying BOTH init(from:) and encode(to:) suppresses the
    // synthesized CodingKeys.
    private enum CodingKeys: String, CodingKey {
        case start, end, control, startHead, endHead
    }

    init(start: CGPoint, end: CGPoint, control: CGPoint? = nil,
         startHead: ArrowHead = .none, endHead: ArrowHead = .arrow) {
        self.start = start; self.end = end; self.control = control
        self.startHead = startHead; self.endHead = endHead
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = (try c.decodeIfPresent(PointSpec.self, forKey: .start))?.point ?? .zero
        end = (try c.decodeIfPresent(PointSpec.self, forKey: .end))?.point ?? .zero
        control = (try c.decodeIfPresent(PointSpec.self, forKey: .control))?.point
        startHead = try c.decodeIfPresent(ArrowHead.self, forKey: .startHead) ?? .none
        endHead = try c.decodeIfPresent(ArrowHead.self, forKey: .endHead) ?? .arrow
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start.spec, forKey: .start)
        try c.encode(end.spec, forKey: .end)
        try c.encodeIfPresent(control?.spec, forKey: .control)
        try c.encode(startHead, forKey: .startHead)
        try c.encode(endHead, forKey: .endHead)
    }
}

enum ArrowHead: String, Equatable, Sendable, Codable {
    case none, arrow, triangle, dot, bar, diamond
}

/// One freehand sample. Pressure is carried from day one — retrofitting
/// width-per-sample into `[CGPoint]` later forces a breaking format bump.
struct StrokeSample: Equatable, Sendable, Codable {
    var point: CGPoint
    /// 0...1; 1.0 for a plain mouse with no pressure hardware.
    var pressure: CGFloat = 1
    /// -1...1 per axis; .zero when unavailable.
    var tilt: CGVector = .zero
    /// Used for velocity-derived width. Seconds, from the NSEvent.
    var timestamp: TimeInterval = 0

    init(point: CGPoint, pressure: CGFloat = 1,
         tilt: CGVector = .zero, timestamp: TimeInterval = 0) {
        self.point = point
        self.pressure = pressure
        self.tilt = tilt
        self.timestamp = timestamp
    }

    // Flat and named — a stroke is the highest-volume thing in the format, and
    // `{"x":40,"y":200,"p":1}` stays both compact and readable. Tilt and
    // timestamp are omitted when they carry no information, which they usually
    // do not for a mouse.
    private enum CodingKeys: String, CodingKey {
        case x, y, p, tx, ty, t
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = CGPoint(x: try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0,
                        y: try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0)
        pressure = try c.decodeIfPresent(CGFloat.self, forKey: .p) ?? 1
        tilt = CGVector(dx: try c.decodeIfPresent(CGFloat.self, forKey: .tx) ?? 0,
                        dy: try c.decodeIfPresent(CGFloat.self, forKey: .ty) ?? 0)
        timestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .t) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(point.x, forKey: .x)
        try c.encode(point.y, forKey: .y)
        if pressure != 1 { try c.encode(pressure, forKey: .p) }
        if tilt.dx != 0 { try c.encode(tilt.dx, forKey: .tx) }
        if tilt.dy != 0 { try c.encode(tilt.dy, forKey: .ty) }
        if timestamp != 0 { try c.encode(timestamp, forKey: .t) }
    }
}

/// The rendered outline is DERIVED from samples, never stored, so changing
/// brush size or thinning re-renders losslessly.
struct StrokePayload: Equatable, Sendable, Codable {
    var samples: [StrokeSample]
    var brush: BrushSpec = BrushSpec()

    var points: [CGPoint] { samples.map(\.point) }

    init(samples: [StrokeSample], brush: BrushSpec = BrushSpec()) {
        self.samples = samples
        self.brush = brush
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent([StrokeSample].self, forKey: .samples) ?? []
        brush = try c.decodeIfPresent(BrushSpec.self, forKey: .brush) ?? BrushSpec()
    }
}

struct BrushSpec: Equatable, Hashable, Sendable, Codable {
    enum Engine: String, Sendable, Codable {
        case pen, pressure, pencil, highlighter, calligraphy, marker
    }

    var engine: Engine = .pen
    var sizePx: CGFloat = 6
    /// perfect-freehand semantics: how much pressure narrows the stroke.
    var thinning: CGFloat = 0.5
    var smoothing: CGFloat = 0.5
    /// The stabilizer.
    var streamline: CGFloat = 0.5
    /// Velocity-derived taper so mouse users still get a tapered stroke.
    var simulatePressure = true
    var nibAngle: CGFloat = .pi / 4    // calligraphy only

    /// Highlighter draws ~3x wider and multiplies; encoded here so hit testing
    /// and rendering agree on the effective width.
    var widthMultiplier: CGFloat {
        engine == .highlighter ? 3 : 1
    }

    var blendMode: CGBlendMode {
        engine == .highlighter ? .multiply : .normal
    }
}

struct TextPayload: Equatable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case string, origin, boxSize, resize, fontName, fontSizePx
        case isBold, isItalic, isUnderlined, alignment, lineHeightMultiple, plateColor
    }

    /// Defining `init(from:)` in the body suppresses the synthesized memberwise
    /// init, so this restores one — every parameter defaulted, so `TextPayload()`
    /// and partial construction both work.
    init(string: String = "", origin: CGPoint = .zero, boxSize: CGSize? = nil,
         resize: Resize = .autoWidth, fontName: String = "Helvetica Neue",
         fontSizePx: CGFloat = 48, isBold: Bool = false, isItalic: Bool = false,
         isUnderlined: Bool = false, alignment: TextAlignment = .left,
         lineHeightMultiple: CGFloat = 1.0, plateColor: RGBAColor? = nil) {
        self.string = string
        self.origin = origin
        self.boxSize = boxSize
        self.resize = resize
        self.fontName = fontName
        self.fontSizePx = fontSizePx
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.alignment = alignment
        self.lineHeightMultiple = lineHeightMultiple
        self.plateColor = plateColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        string = try c.decodeIfPresent(String.self, forKey: .string) ?? ""
        origin = (try c.decodeIfPresent(PointSpec.self, forKey: .origin))?.point ?? .zero
        boxSize = (try c.decodeIfPresent(SizeSpec.self, forKey: .boxSize))?.size
        resize = try c.decodeIfPresent(Resize.self, forKey: .resize) ?? .autoWidth
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica Neue"
        fontSizePx = try c.decodeIfPresent(CGFloat.self, forKey: .fontSizePx) ?? 48
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        isItalic = try c.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        isUnderlined = try c.decodeIfPresent(Bool.self, forKey: .isUnderlined) ?? false
        alignment = try c.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? .left
        lineHeightMultiple = try c.decodeIfPresent(CGFloat.self,
                                                   forKey: .lineHeightMultiple) ?? 1
        plateColor = try c.decodeIfPresent(RGBAColor.self, forKey: .plateColor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(string, forKey: .string)
        try c.encode(origin.spec, forKey: .origin)
        try c.encodeIfPresent(boxSize?.spec, forKey: .boxSize)
        try c.encode(resize, forKey: .resize)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSizePx, forKey: .fontSizePx)
        try c.encode(isBold, forKey: .isBold)
        try c.encode(isItalic, forKey: .isItalic)
        try c.encode(isUnderlined, forKey: .isUnderlined)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(lineHeightMultiple, forKey: .lineHeightMultiple)
        try c.encodeIfPresent(plateColor, forKey: .plateColor)
    }

    /// Figma's three-mode sizing model.
    enum Resize: String, Sendable, Codable { case autoWidth, autoHeight, fixed }

    var string: String = ""
    var origin: CGPoint = .zero
    /// nil when .autoWidth — layout determines the box.
    var boxSize: CGSize? = nil
    var resize: Resize = .autoWidth
    var fontName: String = "Helvetica Neue"
    var fontSizePx: CGFloat = 48
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var alignment: TextAlignment = .left
    var lineHeightMultiple: CGFloat = 1.0
    /// Legibility plate drawn behind the glyphs.
    var plateColor: RGBAColor? = nil
}

enum TextAlignment: String, Equatable, Sendable, Codable {
    case left, center, right, justified
}

struct RasterPayload: Equatable, Sendable, Codable {
    var surface: SurfaceID
    /// Destination in canvas pixels.
    var rect: CGRect
    var intrinsicPixelSize: PixelSize
    var interpolation: CGInterpolationQuality = .high

    private enum CodingKeys: String, CodingKey {
        case surface, rect, intrinsicPixelSize, interpolation
    }

    init(surface: SurfaceID, rect: CGRect, intrinsicPixelSize: PixelSize,
         interpolation: CGInterpolationQuality = .high) {
        self.surface = surface; self.rect = rect
        self.intrinsicPixelSize = intrinsicPixelSize; self.interpolation = interpolation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decode(SurfaceID.self, forKey: .surface)
        rect = (try c.decodeIfPresent(RectSpec.self, forKey: .rect))?.rect ?? .zero
        intrinsicPixelSize = try c.decodeIfPresent(PixelSize.self, forKey: .intrinsicPixelSize)
            ?? PixelSize(width: 0, height: 0)
        let raw = try c.decodeIfPresent(Int32.self, forKey: .interpolation) ?? 0
        interpolation = CGInterpolationQuality(rawValue: raw) ?? .high
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        try c.encode(rect.spec, forKey: .rect)
        try c.encode(intrinsicPixelSize, forKey: .intrinsicPixelSize)
        try c.encode(interpolation.rawValue, forKey: .interpolation)
    }
}

struct FilterPayload: Equatable, Sendable, Codable {
    var region: CGRect
    var descriptor: FilterDescriptor

    private enum CodingKeys: String, CodingKey { case region, descriptor }

    init(region: CGRect, descriptor: FilterDescriptor) {
        self.region = region
        self.descriptor = descriptor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = (try c.decodeIfPresent(RectSpec.self, forKey: .region))?.rect ?? .zero
        descriptor = try c.decode(FilterDescriptor.self, forKey: .descriptor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(region.spec, forKey: .region)
        try c.encode(descriptor, forKey: .descriptor)
    }
}

/// One Codable+Hashable enum, one apply() switch. Generalized from day one;
/// retrofitting it after filters exist is painful.
enum FilterDescriptor: Equatable, Hashable, Sendable, Codable {
    case gaussianBlur(radiusPx: CGFloat)
    case pixelate(blockPx: CGFloat)

    var isRedaction: Bool {
        switch self {
        case .gaussianBlur, .pixelate: return true
        }
    }
}

// MARK: - Flattened path geometry

/// A value-typed path. `CGPath` is neither Equatable, Hashable, nor Sendable in
/// the SDK, and storing one would break synthesized Equatable and therefore
/// `Scene.==`, which `endGesture()`'s push-only-if-changed check depends on.
/// The `CGPath` is derived on demand and never stored.
struct PathGeometry: Equatable, Sendable, Codable {
    var subpaths: [[CGPoint]]
    var evenOdd: Bool = false

    var isEmpty: Bool { subpaths.allSatisfy { $0.count < 2 } }

    private enum CodingKeys: String, CodingKey { case subpaths, evenOdd }

    init(subpaths: [[CGPoint]], evenOdd: Bool = false) {
        self.subpaths = subpaths
        self.evenOdd = evenOdd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let specs = try c.decodeIfPresent([[PointSpec]].self, forKey: .subpaths) ?? []
        subpaths = specs.map { $0.map(\.point) }
        evenOdd = try c.decodeIfPresent(Bool.self, forKey: .evenOdd) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(subpaths.map { $0.map(PointSpec.init) }, forKey: .subpaths)
        try c.encode(evenOdd, forKey: .evenOdd)
    }

    func makePath() -> CGPath {
        let path = CGMutablePath()
        for sub in subpaths where sub.count >= 2 {
            path.move(to: sub[0])
            for p in sub.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
        }
        return path
    }

    var bounds: CGRect {
        subpaths.reduce(CGRect.null) { $0.unionIgnoringNull(CGRect(containing: $1)) }
    }
}
