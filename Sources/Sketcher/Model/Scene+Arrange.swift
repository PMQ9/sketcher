import CoreGraphics
import Foundation

/// Z-order and grouping — the structural half of the arrange commands.
///
/// Z-order is array order within a layer, so reordering never crosses layers: a
/// multi-selection spanning two layers reorders inside each independently, which
/// is what keeps "bring to front" meaningful when layers exist.
extension Scene {
    enum ZOrder { case front, back, forward, backward }

    mutating func reorder(_ ids: Set<UUID>, _ order: ZOrder) {
        guard !ids.isEmpty else { return }
        for li in layers.indices {
            guard case .vector(var objects) = layers[li].content,
                  objects.contains(where: { ids.contains($0.id) }) else { continue }
            Scene.applyReorder(&objects, ids: ids, order: order)
            layers[li].content = .vector(objects)
        }
    }

    private static func applyReorder(_ objects: inout [DrawObject], ids: Set<UUID>,
                                     order: ZOrder) {
        switch order {
        case .front:
            let selected = objects.filter { ids.contains($0.id) }
            objects = objects.filter { !ids.contains($0.id) } + selected
        case .back:
            let selected = objects.filter { ids.contains($0.id) }
            objects = selected + objects.filter { !ids.contains($0.id) }
        case .forward:
            guard objects.count >= 2 else { return }
            // Top-down so each selected element hops at most one place up past
            // the nearest unselected neighbor — a contiguous block moves as one.
            for i in stride(from: objects.count - 2, through: 0, by: -1)
            where ids.contains(objects[i].id) && !ids.contains(objects[i + 1].id) {
                objects.swapAt(i, i + 1)
            }
        case .backward:
            guard objects.count >= 2 else { return }
            for i in 1..<objects.count
            where ids.contains(objects[i].id) && !ids.contains(objects[i - 1].id) {
                objects.swapAt(i, i - 1)
            }
        }
    }

    // MARK: - Groups

    /// The outermost group id of an object (index 0 — outermost first), or nil.
    func outerGroup(of id: UUID) -> UUID? {
        object(with: id)?.groupIDs.first
    }

    /// Expand `ids` to include every object sharing an outermost group with any
    /// of them: groups are atomic for selection, so clicking one member selects
    /// the whole group.
    func expandingGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(ids.compactMap { outerGroup(of: $0) })
        guard !groups.isEmpty else { return ids }
        var result = ids
        for object in allObjects {
            if let g = object.groupIDs.first, groups.contains(g) { result.insert(object.id) }
        }
        return result
    }

    // MARK: - Align / distribute

    enum AlignKind { case left, hCenter, right, top, vCenter, bottom }
    enum DistributeKind { case horizontal, vertical }

    /// Align each selected object's bounding box to the selection's combined box
    /// — Figma/Illustrator behavior when two or more are selected.
    mutating func align(_ ids: Set<UUID>, _ kind: AlignKind) {
        let objects = allObjects.filter { ids.contains($0.id) && !$0.bounds.isNull }
        guard objects.count >= 2 else { return }
        let union = objects.reduce(CGRect.null) { $0.unionIgnoringNull($1.bounds) }
        guard !union.isNull else { return }
        for object in objects {
            let b = object.bounds
            var delta = CGPoint.zero
            switch kind {
            case .left: delta.x = union.minX - b.minX
            case .hCenter: delta.x = union.midX - b.midX
            case .right: delta.x = union.maxX - b.maxX
            case .top: delta.y = union.minY - b.minY
            case .vCenter: delta.y = union.midY - b.midY
            case .bottom: delta.y = union.maxY - b.maxY
            }
            if delta != .zero { withObject(object.id) { $0.translate(by: delta) } }
        }
    }

    /// Even out the spacing of object centers between the two extremes along one
    /// axis. Distributes CENTERS (not gaps), which needs no equal-size assumption.
    mutating func distribute(_ ids: Set<UUID>, _ kind: DistributeKind) {
        let horizontal = kind == .horizontal
        func center(_ o: DrawObject) -> CGFloat {
            horizontal ? o.bounds.midX : o.bounds.midY
        }
        let sorted = allObjects
            .filter { ids.contains($0.id) && !$0.bounds.isNull }
            .sorted { center($0) < center($1) }
        guard sorted.count >= 3, let first = sorted.first, let last = sorted.last else { return }
        let lo = center(first), hi = center(last)
        guard hi > lo else { return }
        let n = sorted.count
        for i in 1..<(n - 1) {
            let target = lo + (hi - lo) * CGFloat(i) / CGFloat(n - 1)
            let delta = target - center(sorted[i])
            let move = horizontal ? CGPoint(x: delta, y: 0) : CGPoint(x: 0, y: delta)
            withObject(sorted[i].id) { $0.translate(by: move) }
        }
    }
}
