import CoreGraphics
import Foundation

/// Pure layer-stack edits on `Scene`. The view model brackets these with history
/// and owns anything that needs the `SurfaceStore` (rasterize, merge, flatten) —
/// these are just the value-type mutations, kept testable in isolation.
extension Scene {
    /// Insert `layer` directly above the layer with `id` (top of the stack when
    /// `id` is nil or unknown) and make it active.
    mutating func insertLayer(_ layer: Layer, above id: Layer.ID?) {
        let target = id.flatMap { index(of: $0) }.map { $0 + 1 } ?? layers.count
        layers.insert(layer, at: min(max(target, 0), layers.count))
        activeLayerID = layer.id
    }

    /// Remove a layer, unless it is the last one — a document always keeps at
    /// least one layer. Reselects a neighbor when the active layer goes.
    @discardableResult
    mutating func removeLayer(_ id: Layer.ID) -> Bool {
        guard layers.count > 1, let idx = index(of: id) else { return false }
        layers.remove(at: idx)
        if activeLayerID == id {
            activeLayerID = layers[min(idx, layers.count - 1)].id
        }
        return true
    }

    /// Move the layer at array index `from` to `to` (bottom→top indices).
    mutating func moveLayer(from: Int, to: Int) {
        guard layers.indices.contains(from), to >= 0, to <= layers.count, from != to
        else { return }
        let layer = layers.remove(at: from)
        let dest = to > from ? to - 1 : to
        layers.insert(layer, at: min(max(dest, 0), layers.count))
    }
}
