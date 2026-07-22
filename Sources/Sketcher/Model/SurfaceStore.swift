import CoreGraphics
import Foundation

/// Refcounted side table of immutable pixel buffers.
///
/// `Scene` holds only `SurfaceID`s into this, which is the single decision that
/// keeps snapshot undo viable in a raster-capable app: a Scene snapshot of a
/// five-raster-layer document is still kilobytes.
///
/// INVARIANT: surfaces are IMMUTABLE. Every pixel operation registers a NEW
/// image rather than mutating one in place, so a history entry can safely hold
/// an ID and trust the pixels behind it never change.
///
/// Deliberately NOT `@MainActor`: `SceneRenderer` reads through this, and the
/// renderer must run off-main for export and cache building. Immutable values
/// behind a lock is the whole synchronization story.
final class SurfaceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var surfaces: [SurfaceID: CGImage] = [:]
    private var refCounts: [SurfaceID: Int] = [:]

    init() {}

    @discardableResult
    func register(_ image: CGImage) -> SurfaceID {
        let id = SurfaceID()
        lock.lock()
        defer { lock.unlock() }
        surfaces[id] = image
        refCounts[id] = 1
        return id
    }

    func image(_ id: SurfaceID) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return surfaces[id]
    }

    func retain(_ id: SurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        guard surfaces[id] != nil else { return }
        refCounts[id, default: 0] += 1
    }

    func release(_ id: SurfaceID) {
        lock.lock()
        defer { lock.unlock() }
        guard let count = refCounts[id] else { return }
        if count <= 1 {
            surfaces.removeValue(forKey: id)
            refCounts.removeValue(forKey: id)
        } else {
            refCounts[id] = count - 1
        }
    }

    /// Distinct backing stores, deduplicated by identity — the eviction budget
    /// is measured against this, not against entry count.
    ///
    /// NOTE: this counts what each `CGImage` reports, which is only honest if
    /// every registered image owns its pixels. `CGImage.cropping(to:)` does NOT
    /// copy — it retains the parent — so a cropped image would under-report by
    /// the size of the whole canvas it secretly pins. Always materialize crops
    /// into a fresh context before registering them.
    var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<ObjectIdentifier>()
        var total = 0
        for image in surfaces.values {
            guard seen.insert(ObjectIdentifier(image)).inserted else { continue }
            total += image.height * image.bytesPerRow
        }
        return total
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return surfaces.count
    }

    /// Drop everything not referenced by `ids`. Called after delete and undo so
    /// orphaned surfaces do not accumulate.
    func prune(keeping ids: Set<SurfaceID>) {
        lock.lock()
        defer { lock.unlock() }
        for id in surfaces.keys where !ids.contains(id) {
            surfaces.removeValue(forKey: id)
            refCounts.removeValue(forKey: id)
        }
    }
}

extension Scene {
    /// Every surface this scene references — the keep-set for `prune`.
    var referencedSurfaceIDs: Set<SurfaceID> {
        var ids = Set<SurfaceID>()
        for layer in layers {
            switch layer.content {
            case .raster(let id):
                ids.insert(id)
            case .vector(let objects):
                for object in objects {
                    if case .image(let payload) = object.kind { ids.insert(payload.surface) }
                }
            }
        }
        return ids
    }
}
