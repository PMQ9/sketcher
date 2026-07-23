import CoreGraphics
import Foundation

/// The 1€ filter (Casiez, Roussel, Vogel, 2012) — an adaptive low-pass that
/// removes pointer jitter without the lag a fixed low-pass adds to fast motion.
///
/// This is the brush stabilizer. It runs at CAPTURE time: raw pointer points go
/// in, smoothed points are stored. `Freehand` then derives the outline from the
/// stored (already-stabilized) samples. Deliberately split this way — jitter is
/// a property of the input device, geometry is a property of the mark — so the
/// two never fight over the same knob.
///
/// The core idea: the low-pass cutoff RISES with speed. Slow, deliberate motion
/// is smoothed hard (kills tremor); fast motion is barely filtered (no lag).
///
/// A value type with explicit `dt`, so it is pure and unit-testable: the same
/// point/dt sequence always yields the same output, independent of wall-clock.
struct OneEuroFilter {
    /// Minimum cutoff frequency (Hz). Lower = more smoothing at rest. This is
    /// the knob the stabilizer slider drives.
    var minCutoff: CGFloat
    /// Speed coefficient. Higher = cutoff rises faster with speed = less lag.
    var beta: CGFloat
    /// Cutoff for the derivative estimate. 1 Hz is the paper's default.
    var derivativeCutoff: CGFloat

    private var xPrev: CGPoint?
    private var dxPrev = CGVector.zero
    private var initialized = false

    init(minCutoff: CGFloat = 1.0, beta: CGFloat = 0.007,
         derivativeCutoff: CGFloat = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// Feed one raw sample and its time delta (seconds); returns the smoothed
    /// point. `dt <= 0` (the first sample, or a duplicate timestamp) passes the
    /// point through untouched and seeds the filter.
    mutating func filter(_ point: CGPoint, dt: CGFloat) -> CGPoint {
        guard initialized, let prev = xPrev, dt > 0 else {
            xPrev = point
            dxPrev = .zero
            initialized = true
            return point
        }

        // Estimate speed (low-passed) and raise the cutoff proportionally.
        let dx = CGVector(dx: (point.x - prev.x) / dt, dy: (point.y - prev.y) / dt)
        let edx = lowpass(dx, previous: dxPrev, alpha: alpha(cutoff: derivativeCutoff, dt: dt))
        dxPrev = edx

        let speed = hypot(edx.dx, edx.dy)
        let cutoff = minCutoff + beta * speed
        let smoothed = lowpass(point, previous: prev, alpha: alpha(cutoff: cutoff, dt: dt))
        xPrev = smoothed
        return smoothed
    }

    /// Smoothing factor for a given cutoff and timestep. Larger alpha = less
    /// smoothing (follows the input more closely).
    private func alpha(cutoff: CGFloat, dt: CGFloat) -> CGFloat {
        let tau = 1 / (2 * .pi * max(cutoff, 0.0001))
        return 1 / (1 + tau / dt)
    }

    private func lowpass(_ x: CGPoint, previous: CGPoint, alpha: CGFloat) -> CGPoint {
        CGPoint(x: alpha * x.x + (1 - alpha) * previous.x,
                y: alpha * x.y + (1 - alpha) * previous.y)
    }

    private func lowpass(_ x: CGVector, previous: CGVector, alpha: CGFloat) -> CGVector {
        CGVector(dx: alpha * x.dx + (1 - alpha) * previous.dx,
                 dy: alpha * x.dy + (1 - alpha) * previous.dy)
    }

    /// Configure from a brush's `streamline` (0…1). 0 barely touches the input;
    /// 1 smooths aggressively. Maps to a falling minCutoff and rising beta.
    static func forStreamline(_ streamline: CGFloat) -> OneEuroFilter {
        let s = min(max(streamline, 0), 1)
        // minCutoff 4 Hz (light) down to ~0.3 Hz (heavy); beta grows so fast
        // strokes stay lag-free even under heavy smoothing.
        return OneEuroFilter(minCutoff: 4 - s * 3.7,
                             beta: 0.003 + s * 0.02,
                             derivativeCutoff: 1.0)
    }
}
