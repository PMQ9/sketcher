import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// The pixels a redaction bakes in.
///
/// Renders the composited region through the SHARED renderer (so it blurs
/// exactly what the canvas shows), applies the filter, and returns an opaque
/// patch. Destructive by design (D11): the caller deletes the covered vector
/// geometry, so nothing under the blur remains recoverable in the file.
enum Redaction {
    static func render(scene: Scene, surfaces: SurfaceStore, region: CGRect,
                       descriptor: FilterDescriptor) -> CGImage? {
        guard let base = ExportService.renderRegion(scene, surfaces: surfaces, rect: region)
        else { return nil }

        let input = CIImage(cgImage: base)
        let extent = input.extent
        let output: CIImage

        switch descriptor {
        case .gaussianBlur(let radius):
            // Clamp before the convolution and crop after, or the blur samples
            // transparent black past the edge and draws a dark halo.
            output = input.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(max(radius, 1)))
                .cropped(to: extent)
        case .pixelate(let block):
            let filter = CIFilter.pixellate()
            filter.inputImage = input.clampedToExtent()
            filter.scale = Float(max(block, 1))
            // Anchor the block grid to the region origin so the blocks do not
            // crawl if the region is ever re-rendered at a different offset.
            filter.center = CGPoint(x: extent.minX, y: extent.minY)
            output = (filter.outputImage ?? input).cropped(to: extent)
        }

        return CIContextProvider.shared.createCGImage(output, from: extent,
                                                      format: .RGBA8,
                                                      colorSpace: scene.canvas.cgColorSpace)
    }
}
