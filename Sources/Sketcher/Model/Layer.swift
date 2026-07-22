import CoreGraphics
import Foundation

/// Opaque handle into `SurfaceStore`. Because `Scene` holds only the ID, a
/// Scene snapshot stays kilobytes even for a document with five raster layers
/// — which is the single decision that keeps snapshot undo viable in a
/// raster-capable app.
struct SurfaceID: Equatable, Hashable, Sendable, Codable {
    let raw: UUID
    init(raw: UUID = UUID()) { self.raw = raw }
}

struct Layer: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isVisible = true
    var isLocked = false
    var opacity: CGFloat = 1.0
    var blend: CGBlendMode = .normal
    var content: LayerContent

    init(id: UUID = UUID(), name: String, content: LayerContent) {
        self.id = id
        self.name = name
        self.content = content
    }

    /// True when this layer composites straight into the backdrop with no
    /// isolation, so filters below it can sample everything beneath them.
    /// The common case — and the fast path, since it needs no offscreen.
    var isTransparent: Bool { opacity == 1.0 && blend == .normal }

    var isVector: Bool {
        if case .vector = content { return true }
        return false
    }

    var isRaster: Bool { !isVector }

    /// Editable objects, or [] for a raster layer.
    var objects: [DrawObject] {
        get {
            if case .vector(let objs) = content { return objs }
            return []
        }
        set { content = .vector(newValue) }
    }

    /// Whether this layer accepts edits at all.
    var isEditable: Bool { isVisible && !isLocked }

    static func vector(named name: String) -> Layer {
        Layer(name: name, content: .vector([]))
    }
}

enum LayerContent: Equatable, Sendable {
    case vector([DrawObject])
    /// Handle only — pixels never live in `Scene`.
    case raster(SurfaceID)
}
