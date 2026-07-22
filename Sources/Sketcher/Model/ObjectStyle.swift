import CoreGraphics

/// Un-premultiplied color in the canvas color space.
struct RGBAColor: Equatable, Hashable, Sendable, Codable {
    var r, g, b, a: CGFloat

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// Rec. 709 luma — used to pick ink that is visible against a background.
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func withAlpha(_ newAlpha: CGFloat) -> RGBAColor {
        RGBAColor(r: r, g: g, b: b, a: newAlpha)
    }

    static let black = RGBAColor(r: 0.09, g: 0.09, b: 0.10)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let red = RGBAColor(r: 0.93, g: 0.19, b: 0.14)
    static let orange = RGBAColor(r: 1.0, g: 0.58, b: 0.0)
    static let yellow = RGBAColor(r: 1.0, g: 0.85, b: 0.16)
    static let green = RGBAColor(r: 0.16, g: 0.72, b: 0.30)
    static let blue = RGBAColor(r: 0.04, g: 0.44, b: 0.98)
    static let purple = RGBAColor(r: 0.58, g: 0.31, b: 0.92)
}

enum Fill: Equatable, Sendable {
    case none
    case solid(RGBAColor)

    var color: RGBAColor? {
        if case .solid(let c) = self { return c }
        return nil
    }

    var isVisible: Bool {
        guard case .solid(let c) = self else { return false }
        return c.a > 0
    }
}

/// String-backed so it reads as `"dash": "dashed"` in a saved document.
/// Swift's synthesized `Codable` for a case-only enum emits `{"dashed":{}}`,
/// which is pure noise in a file a human may open.
enum DashStyle: String, Equatable, Sendable, Codable {
    case solid
    case dashed
    case dotted

    /// Dash lengths scale with stroke width so the pattern reads the same at
    /// every weight.
    func lengths(strokeWidth w: CGFloat) -> [CGFloat]? {
        switch self {
        case .solid: return nil
        case .dashed: return [w * 3, w * 2]
        case .dotted: return [w * 0.01, w * 2]   // near-zero dash + round cap = dot
        }
    }
}

struct ShadowSpec: Equatable, Sendable {
    var offset: CGSize
    var blurRadiusPx: CGFloat
    var color: RGBAColor

    static let subtle = ShadowSpec(offset: CGSize(width: 0, height: 2),
                                   blurRadiusPx: 6,
                                   color: RGBAColor(r: 0, g: 0, b: 0, a: 0.35))
}

/// Every field has a default so older saved documents (and older undo
/// snapshots) keep decoding as new style axes are added.
struct ObjectStyle: Equatable, Sendable {
    var strokeColor: RGBAColor? = .black       // nil = no stroke
    var fill: Fill = .none
    var strokeWidthPx: CGFloat = 6
    var dash: DashStyle = .solid
    var lineCap: CGLineCap = .round
    var lineJoin: CGLineJoin = .round
    var opacity: CGFloat = 1.0
    var blend: CGBlendMode = .normal
    var shadow: ShadowSpec? = nil
    var antialias = true

    var hasVisibleStroke: Bool {
        guard let c = strokeColor else { return false }
        return c.a > 0 && strokeWidthPx > 0
    }

    /// Default style for a fresh document, inked so the first mark is visible
    /// against the chosen canvas background.
    static func `default`(ink: RGBAColor) -> ObjectStyle {
        ObjectStyle(strokeColor: ink)
    }
}
