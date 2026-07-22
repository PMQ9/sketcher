import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `CGImageDestination` wrapper for the raster export formats.
enum ImageExporter {

    enum Format: String, CaseIterable, Sendable {
        case png, jpeg, tiff, heic

        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            case .heic: return UTType("public.heic") ?? .png
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .tiff: return "tiff"
            case .heic: return "heic"
            }
        }

        var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .tiff: return "TIFF"
            case .heic: return "HEIC"
            }
        }

        /// PNG and TIFF keep alpha; JPEG and HEIC flatten it.
        var supportsTransparency: Bool {
            switch self {
            case .png, .tiff: return true
            case .jpeg, .heic: return false
            }
        }
    }

    static func data(_ image: CGImage, format: Format,
                     pixelsPerPoint: CGFloat = 1,
                     quality: CGFloat = 0.9) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, format.utType.identifier as CFString, 1, nil) else { return nil }

        // 72 dpi is the 1x baseline, so a 2x canvas stamps 144 and opens at
        // natural size in Preview, Mail, and Word rather than doubled.
        let dpi = 72 * Double(max(pixelsPerPoint, 1))
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        if format == .jpeg || format == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func write(_ image: CGImage, to url: URL, format: Format,
                      pixelsPerPoint: CGFloat = 1, quality: CGFloat = 0.9) throws {
        guard let data = data(image, format: format,
                              pixelsPerPoint: pixelsPerPoint, quality: quality) else {
            throw ExportError.encodingFailed(format)
        }
        try data.write(to: url, options: .atomic)
    }

    static func read(contentsOf url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    enum ExportError: LocalizedError {
        case encodingFailed(Format)
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let format):
                return "Could not encode the image as \(format.displayName)."
            case .renderFailed:
                return "Could not render the canvas. It may be too large."
            }
        }
    }
}
