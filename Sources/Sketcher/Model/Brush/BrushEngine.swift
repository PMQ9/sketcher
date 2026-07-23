import CoreGraphics
import Foundation

/// Maps the six brush presets onto `Freehand.Options`, and builds the outline a
/// `.stroke` object renders. One switch, so the renderer, hit testing, and the
/// export pipeline all agree on a stroke's shape.
///
/// The presets are the visible product of the engine: `pen` is a clean constant
/// line, `pressure` is fully pressure-driven, `highlighter` is a wide multiply
/// wash, `calligraphy` fakes a nib by modulating per-sample pressure from stroke
/// direction, and so on. All of it flows through the single `Freehand.outline`.
enum BrushEngine {
    /// Freehand options for a brush. `size` folds in the width multiplier so the
    /// highlighter is genuinely ~3× wide rather than merely styled that way.
    static func options(for brush: BrushSpec) -> Freehand.Options {
        let size = max(brush.sizePx * brush.widthMultiplier, 0.5)
        var o = Freehand.Options(size: size, smoothing: brush.smoothing,
                                 simulatePressure: brush.simulatePressure)
        switch brush.engine {
        case .pen:
            // A clean, confident line: constant width, ignore pressure.
            o.thinning = 0
            o.simulatePressure = false
        case .pressure:
            // The expressive default — pressure (or velocity) fully in charge.
            o.thinning = 0.6
        case .pencil:
            // Lighter and more responsive, a touch of end taper.
            o.thinning = 0.5
            o.taperEnd = size
        case .highlighter:
            // Flat, even wash. Width must not wander or the multiply overlaps
            // read as banding.
            o.thinning = 0
            o.simulatePressure = false
        case .calligraphy:
            // Width comes from `inputPoints` (nib modulation), so pressure fully
            // drives the radius here and velocity simulation is off.
            o.thinning = 0.85
            o.simulatePressure = false
        case .marker:
            // Bold and nearly uniform, with only a hint of pressure.
            o.thinning = 0.15
        }
        return o
    }

    /// The samples as freehand inputs. Every engine passes pressure straight
    /// through except `calligraphy`, which replaces it with a nib angle response
    /// so the stroke is thick across the nib and thin along it.
    static func inputPoints(for payload: StrokePayload) -> [Freehand.InputPoint] {
        let samples = payload.samples
        guard payload.brush.engine == .calligraphy, samples.count > 1 else {
            return samples.map { Freehand.InputPoint(point: $0.point, pressure: $0.pressure) }
        }
        let nib = payload.brush.nibAngle
        var out: [Freehand.InputPoint] = []
        out.reserveCapacity(samples.count)
        for i in samples.indices {
            let prev = samples[i == 0 ? 0 : i - 1].point
            let curr = samples[i].point
            let dx = curr.x - prev.x, dy = curr.y - prev.y
            let pressure: CGFloat
            if dx == 0 && dy == 0 {
                pressure = 1
            } else {
                // |sin(travel − nib)|: full width perpendicular to the nib,
                // floored at 0.18 so a parallel stroke stays visible.
                let angle = atan2(dy, dx)
                pressure = max(abs(sin(angle - nib)), 0.18)
            }
            out.append(Freehand.InputPoint(point: curr, pressure: pressure))
        }
        return out
    }

    /// The closed outline polygon for a stored stroke — what the renderer fills.
    static func outline(for payload: StrokePayload) -> [CGPoint] {
        Freehand.outline(inputPoints(for: payload), options: options(for: payload.brush))
    }
}

extension BrushSpec.Engine {
    /// Shift+B cycles through the presets in this order.
    static let cycleOrder: [BrushSpec.Engine] =
        [.pen, .pressure, .pencil, .highlighter, .calligraphy, .marker]

    var next: BrushSpec.Engine {
        let order = Self.cycleOrder
        let i = order.firstIndex(of: self) ?? 0
        return order[(i + 1) % order.count]
    }

    var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .pressure: return "Pressure"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        case .calligraphy: return "Calligraphy"
        case .marker: return "Marker"
        }
    }
}
