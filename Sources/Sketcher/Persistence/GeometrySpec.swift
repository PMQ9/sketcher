import CoreGraphics
import Foundation

// Named, flat encodings for the geometry types in the document format.
//
// WHY these exist: CoreGraphics' own `Codable` conformances encode POSITIONALLY
// — `CGPoint` as `[x,y]`, `CGSize` as `[w,h]`, `CGRect` as `[[x,y],[w,h]]`.
// That is compact but has two problems for a document format:
//
//   1. It is opaque. `"rect": [[20,20],[100,60]]` in a saved file cannot be read
//      or hand-edited without knowing the convention.
//   2. The representation is a Foundation implementation detail, not a
//      documented contract. If it ever changed, every saved file would break.
//
// So the persistence layer speaks these instead, and the model keeps using
// plain CoreGraphics types.

struct PointSpec: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct SizeSpec: Codable, Equatable {
    var width: CGFloat
    var height: CGFloat

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
    }

    var size: CGSize { CGSize(width: width, height: height) }
}

/// Flat on purpose: `{"x":20,"y":20,"width":100,"height":60}` reads better in a
/// document than a nested origin/size pair.
struct RectSpec: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct VectorSpec: Codable, Equatable {
    var dx: CGFloat
    var dy: CGFloat

    init(_ vector: CGVector) {
        dx = vector.dx
        dy = vector.dy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dx = try c.decodeIfPresent(CGFloat.self, forKey: .dx) ?? 0
        dy = try c.decodeIfPresent(CGFloat.self, forKey: .dy) ?? 0
    }

    var vector: CGVector { CGVector(dx: dx, dy: dy) }
}

// MARK: - Convenience

extension CGPoint {
    var spec: PointSpec { PointSpec(self) }
}

extension CGSize {
    var spec: SizeSpec { SizeSpec(self) }
}

extension CGRect {
    var spec: RectSpec { RectSpec(self) }
}

extension CGVector {
    var spec: VectorSpec { VectorSpec(self) }
}
