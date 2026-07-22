import CoreGraphics

/// The ONLY place canvas-pixel ↔ view-point mapping happens. Gestures, hit
/// tolerance, overlay positioning, and canvas drawing all go through this
/// struct; no other code multiplies by a scale factor.
///
/// This is what makes the view layer replaceable in one file: nothing in
/// Model/, ViewModel/, Raster/, or Rendering/ knows about points or zoom.
struct CanvasTransform: Equatable {
    /// View points per canvas pixel.
    var scale: CGFloat
    /// View-point position of the canvas's top-left corner.
    var offset: CGPoint

    static let minScale: CGFloat = 0.05    // 5%
    static let maxScale: CGFloat = 32.0    // 3200%

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin),
               size: CGSize(width: r.width * scale, height: r.height * scale))
    }

    func toCanvas(_ r: CGRect) -> CGRect {
        CGRect(origin: toCanvas(r.origin),
               size: CGSize(width: r.width / scale, height: r.height / scale))
    }

    /// A constant on-screen tolerance (view points) expressed in canvas pixels,
    /// so hit slop feels identical at every zoom level.
    func canvasTolerance(viewPoints: CGFloat) -> CGFloat {
        viewPoints / scale
    }

    /// Zoom about a fixed view point — the point under the cursor stays put.
    /// Derivation: canvas point c under cursor v satisfies v = c*s + o, so
    /// holding c fixed across a scale change gives o' = v - (v - o) * (s'/s).
    mutating func zoom(by factor: CGFloat, about viewPoint: CGPoint) {
        let newScale = (scale * factor).clamped(to: Self.minScale...Self.maxScale)
        guard newScale != scale else { return }
        let ratio = newScale / scale
        offset = CGPoint(x: viewPoint.x - (viewPoint.x - offset.x) * ratio,
                         y: viewPoint.y - (viewPoint.y - offset.y) * ratio)
        scale = newScale
    }

    mutating func setScale(_ newScale: CGFloat, about viewPoint: CGPoint) {
        let clamped = newScale.clamped(to: Self.minScale...Self.maxScale)
        guard clamped != scale, scale > 0 else { return }
        zoom(by: clamped / scale, about: viewPoint)
    }

    mutating func pan(by delta: CGPoint) {
        offset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
    }

    /// Aspect-fit the canvas in the view, centered, never upscaling beyond
    /// natural on-screen size (1 canvas px = 1 device px on a matching display).
    static func fit(pixelSize: CGSize, in viewSize: CGSize,
                    pixelsPerPoint: CGFloat, padding: CGFloat = 40) -> CanvasTransform {
        guard pixelSize.width > 0, pixelSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return CanvasTransform(scale: 1, offset: .zero)
        }
        let available = CGSize(width: max(viewSize.width - padding * 2, 1),
                               height: max(viewSize.height - padding * 2, 1))
        let scale = min(available.width / pixelSize.width,
                        available.height / pixelSize.height,
                        1 / pixelsPerPoint)
            .clamped(to: minScale...maxScale)
        return CanvasTransform(scale: scale,
                               offset: centeringOffset(pixelSize: pixelSize,
                                                       viewSize: viewSize, scale: scale))
    }

    /// Natural size (100%): 1 canvas pixel = 1 device pixel, centered.
    static func actualSize(pixelSize: CGSize, in viewSize: CGSize,
                           pixelsPerPoint: CGFloat) -> CanvasTransform {
        let scale = (1 / pixelsPerPoint).clamped(to: minScale...maxScale)
        return CanvasTransform(scale: scale,
                               offset: centeringOffset(pixelSize: pixelSize,
                                                       viewSize: viewSize, scale: scale))
    }

    private static func centeringOffset(pixelSize: CGSize, viewSize: CGSize,
                                        scale: CGFloat) -> CGPoint {
        CGPoint(x: (viewSize.width - pixelSize.width * scale) / 2,
                y: (viewSize.height - pixelSize.height * scale) / 2)
    }

    /// The canvas rect currently visible in a view of `viewSize`. Used to clip
    /// and cull when rendering live above 100%.
    func visibleCanvasRect(viewSize: CGSize) -> CGRect {
        toCanvas(CGRect(origin: .zero, size: viewSize))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
