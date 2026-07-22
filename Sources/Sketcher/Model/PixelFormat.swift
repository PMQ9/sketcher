import CoreGraphics

/// The ONE canonical pixel layout, declared once and asserted at every raw
/// buffer entry point. Two files specifying different layouts is exactly how a
/// swapped red/blue channel ships.
///
/// 8 bits/component, premultipliedFirst | byteOrder32Little == BGRA in memory.
/// This is the layout CoreGraphics is fastest with on Apple silicon.
enum PixelFormat {
    static let bitsPerComponent = 8
    static let bytesPerPixel = 4

    static let bitmapInfo: CGBitmapInfo = [
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
        .byteOrder32Little
    ]

    /// Byte offsets within one pixel, given the layout above.
    enum Channel {
        static let blue = 0
        static let green = 1
        static let red = 2
        static let alpha = 3
    }

    static func bytesPerRow(width: Int) -> Int {
        width * bytesPerPixel
    }

    /// A fresh transparent bitmap context in the canonical layout.
    /// Returns nil rather than trapping — every CGContext allocation is a
    /// handled failure path, because a large canvas can legitimately fail.
    static func makeContext(width: Int, height: Int,
                            colorSpace: CGColorSpace) -> CGContext? {
        guard width > 0, height > 0,
              width <= CanvasSpec.maxSide, height <= CanvasSpec.maxSide,
              width * height <= CanvasSpec.maxPixels else { return nil }
        return CGContext(data: nil,
                         width: width,
                         height: height,
                         bitsPerComponent: bitsPerComponent,
                         bytesPerRow: 0,   // let CG choose an aligned stride
                         space: colorSpace,
                         bitmapInfo: bitmapInfo.rawValue)
    }

    /// True when `image` already matches the canonical layout, so raw buffer
    /// access is safe without a normalizing redraw.
    static func matches(_ image: CGImage) -> Bool {
        image.bitsPerComponent == bitsPerComponent
            && image.bitsPerPixel == bytesPerPixel * 8
            && image.alphaInfo == .premultipliedFirst
            && image.byteOrderInfo == .order32Little
    }
}

/// Un-premultiplied RGBA comparison. Tolerance and eyedropper checks MUST use
/// this: premultiplied bytes read darkened everywhere alpha < 1, which on a
/// transparent canvas is most pixels.
@inline(__always)
func unpremultiply(r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    guard a > 0 else { return (0, 0, 0, 0) }
    let af = CGFloat(a) / 255
    return (CGFloat(r) / 255 / af, CGFloat(g) / 255 / af, CGFloat(b) / 255 / af, af)
}
