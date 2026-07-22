import CoreGraphics
import Foundation

/// Converts `ObjectKind` to and from an opaque JSON payload.
///
/// Kept separate from `ObjectKind` itself so the model never imports the
/// persistence format — and so an unrecognized `type` can be handed straight
/// back out as `JSONValue` without the model needing a case for it.
enum KindCodec {
    static func payload(for kind: ObjectKind) -> JSONValue {
        switch kind {
        case .rectangle(let rect, let cornerRadius):
            return .from(BoxSpec(rect: rect, cornerRadius: cornerRadius))
        case .ellipse(let rect):
            return .from(BoxSpec(rect: rect, cornerRadius: 0))
        case .polygon(let rect, let sides, let ratio):
            return .from(PolygonSpec(rect: rect, sides: sides, starInnerRatio: ratio))
        case .line(let start, let end, let control):
            return .from(LineSpec(start: start, end: end, control: control))
        case .polyline(let points, let closed):
            return .from(PolylineSpec(points: points, closed: closed))
        case .arrow(let payload):
            return .from(payload)
        case .stroke(let payload):
            return .from(payload)
        case .text(let payload):
            return .from(payload)
        case .image(let payload):
            return .from(payload)
        case .filter(let payload):
            return .from(payload)
        case .unknown:
            return .null
        }
    }

    /// Returns nil for an unrecognized type, which is the signal to keep the
    /// payload verbatim rather than dropping the object.
    static func kind(type: String, payload: JSONValue) -> ObjectKind? {
        switch type {
        case "rectangle":
            guard let spec = payload.decode(BoxSpec.self) else { return nil }
            return .rectangle(rect: spec.rect.rect, cornerRadius: spec.cornerRadius)
        case "ellipse":
            guard let spec = payload.decode(BoxSpec.self) else { return nil }
            return .ellipse(rect: spec.rect.rect)
        case "polygon":
            guard let spec = payload.decode(PolygonSpec.self) else { return nil }
            return .polygon(rect: spec.rect.rect, sides: spec.sides,
                            starInnerRatio: spec.starInnerRatio)
        case "line":
            guard let spec = payload.decode(LineSpec.self) else { return nil }
            return .line(start: spec.start.point, end: spec.end.point,
                         control: spec.control?.point)
        case "polyline":
            guard let spec = payload.decode(PolylineSpec.self) else { return nil }
            return .polyline(points: spec.points.map(\.point), closed: spec.closed)
        case "arrow":
            guard let spec = payload.decode(ArrowPayload.self) else { return nil }
            return .arrow(spec)
        case "stroke":
            guard let spec = payload.decode(StrokePayload.self) else { return nil }
            return .stroke(spec)
        case "text":
            guard let spec = payload.decode(TextPayload.self) else { return nil }
            return .text(spec)
        case "image":
            guard let spec = payload.decode(RasterPayload.self) else { return nil }
            return .image(spec)
        case "filter":
            guard let spec = payload.decode(FilterPayload.self) else { return nil }
            return .filter(spec)
        default:
            return nil
        }
    }

    // MARK: - Per-kind payload shapes

    private struct BoxSpec: Codable {
        var rect: RectSpec
        var cornerRadius: CGFloat

        init(rect: CGRect, cornerRadius: CGFloat) {
            self.rect = rect.spec
            self.cornerRadius = cornerRadius
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rect = try c.decodeIfPresent(RectSpec.self, forKey: .rect) ?? CGRect.zero.spec
            cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 0
        }
    }

    private struct PolygonSpec: Codable {
        var rect: RectSpec
        var sides: Int
        var starInnerRatio: CGFloat?

        init(rect: CGRect, sides: Int, starInnerRatio: CGFloat?) {
            self.rect = rect.spec
            self.sides = sides
            self.starInnerRatio = starInnerRatio
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rect = try c.decodeIfPresent(RectSpec.self, forKey: .rect) ?? CGRect.zero.spec
            sides = try c.decodeIfPresent(Int.self, forKey: .sides) ?? 5
            starInnerRatio = try c.decodeIfPresent(CGFloat.self, forKey: .starInnerRatio)
        }
    }

    private struct LineSpec: Codable {
        var start: PointSpec
        var end: PointSpec
        var control: PointSpec?

        init(start: CGPoint, end: CGPoint, control: CGPoint?) {
            self.start = start.spec
            self.end = end.spec
            self.control = control?.spec
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decodeIfPresent(PointSpec.self, forKey: .start) ?? CGPoint.zero.spec
            end = try c.decodeIfPresent(PointSpec.self, forKey: .end) ?? CGPoint.zero.spec
            control = try c.decodeIfPresent(PointSpec.self, forKey: .control)
        }
    }

    private struct PolylineSpec: Codable {
        var points: [PointSpec]
        var closed: Bool

        init(points: [CGPoint], closed: Bool) {
            self.points = points.map(PointSpec.init)
            self.closed = closed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            points = try c.decodeIfPresent([PointSpec].self, forKey: .points) ?? []
            closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        }
    }
}

// MARK: - JSONValue bridging

extension JSONValue {
    /// Encode any `Encodable` into the opaque payload representation.
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }

    /// Decode this payload into a concrete type, or nil if it does not match.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
