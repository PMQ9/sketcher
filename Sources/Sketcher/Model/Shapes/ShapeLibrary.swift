import CoreGraphics
import Foundation

/// The shape picker's catalog — one data table, so adding a shape is a single
/// row rather than a new tool, menu item, and dispatch case.
///
/// Every entry maps onto the EXISTING `polygon(sides:starInnerRatio:)` kind, so
/// the whole library renders, hit-tests, resizes, rotates, and serializes
/// through paths that already exist. Shapes that do not reduce to a regular
/// polygon or star — callout bubbles, hearts, clouds — are deferred, because
/// each needs a new `ObjectKind` threaded through the renderer, hit test, codec,
/// and resize math; they are not free the way these are.
struct ShapeLibrary {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        /// SF Symbol for the picker button.
        let symbol: String
        let sides: Int
        /// nil for a regular polygon; the inner/outer radius ratio for a star.
        let starInnerRatio: CGFloat?
    }

    static let entries: [Entry] = [
        // Regular polygons — vertex 0 points up, so a triangle stands on its base.
        Entry(name: "Triangle", symbol: "triangle", sides: 3, starInnerRatio: nil),
        Entry(name: "Diamond", symbol: "diamond", sides: 4, starInnerRatio: nil),
        Entry(name: "Pentagon", symbol: "pentagon", sides: 5, starInnerRatio: nil),
        Entry(name: "Hexagon", symbol: "hexagon", sides: 6, starInnerRatio: nil),
        Entry(name: "Heptagon", symbol: "seal", sides: 7, starInnerRatio: nil),
        Entry(name: "Octagon", symbol: "octagon", sides: 8, starInnerRatio: nil),
        Entry(name: "Nonagon", symbol: "seal", sides: 9, starInnerRatio: nil),
        Entry(name: "Decagon", symbol: "seal", sides: 10, starInnerRatio: nil),
        Entry(name: "Dodecagon", symbol: "seal", sides: 12, starInnerRatio: nil),

        // Stars and bursts.
        Entry(name: "Three-Point Star", symbol: "star", sides: 3, starInnerRatio: 0.4),
        Entry(name: "Four-Point Star", symbol: "sparkle", sides: 4, starInnerRatio: 0.4),
        Entry(name: "Five-Point Star", symbol: "star", sides: 5, starInnerRatio: 0.38),
        Entry(name: "Six-Point Star", symbol: "star", sides: 6, starInnerRatio: 0.5),
        Entry(name: "Seven-Point Star", symbol: "star", sides: 7, starInnerRatio: 0.45),
        Entry(name: "Eight-Point Star", symbol: "star", sides: 8, starInnerRatio: 0.5),
        Entry(name: "Twelve-Point Star", symbol: "star", sides: 12, starInnerRatio: 0.6),
        Entry(name: "Sparkle", symbol: "sparkle", sides: 4, starInnerRatio: 0.26),
        Entry(name: "Sharp Star", symbol: "star", sides: 5, starInnerRatio: 0.25),
        Entry(name: "Sun", symbol: "star", sides: 16, starInnerRatio: 0.72),
        Entry(name: "Burst", symbol: "sparkles", sides: 20, starInnerRatio: 0.78),
    ]

    static let `default` = entries.first { $0.name == "Pentagon" } ?? entries[0]
}
