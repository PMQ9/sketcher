import CoreGraphics

extension CGImage {
    /// The top-left pixel as UN-premultiplied RGBA in `colorSpace`.
    ///
    /// The eyedropper reads through this: premultiplied bytes read darkened
    /// everywhere alpha < 1, so a straight readback would sample the wrong color
    /// on anything translucent (invariant 10). The image is redrawn into a 1×1
    /// canonical-format context, so the source layout does not matter.
    func firstPixelUnpremultiplied(colorSpace: CGColorSpace) -> RGBAColor? {
        var bytes: [UInt8] = [0, 0, 0, 0]
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: PixelFormat.bitsPerComponent,
                                      bytesPerRow: PixelFormat.bytesPerPixel,
                                      space: colorSpace,
                                      bitmapInfo: PixelFormat.bitmapInfo.rawValue) else {
                return false
            }
            ctx.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        let (r, g, b, a) = unpremultiply(r: bytes[PixelFormat.Channel.red],
                                         g: bytes[PixelFormat.Channel.green],
                                         b: bytes[PixelFormat.Channel.blue],
                                         a: bytes[PixelFormat.Channel.alpha])
        return RGBAColor(r: r, g: g, b: b, a: a)
    }
}
