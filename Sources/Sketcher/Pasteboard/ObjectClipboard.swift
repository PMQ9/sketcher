import AppKit
import CoreGraphics
import Foundation

/// Object-level copy / paste through the system pasteboard.
///
/// A copy writes THREE representations so both Sketcher and other apps can
/// consume it:
/// - a private UTI carrying lossless object JSON — round-trips geometry, style,
///   rotation, group membership, and even object types this build does not
///   recognize (via the same `ObjectSpec` the document format uses);
/// - PNG and TIFF renders of the selected objects, so pasting into Mail,
///   Preview, or a browser yields an image.
///
/// Reading is object-JSON ONLY. Pasting an EXTERNAL image as a raster object
/// waits for M6/M7, which build the `SurfaceStore` lifecycle across undo/redo —
/// pruning a freshly registered surface on undo would otherwise lose its pixels
/// on redo.
enum ObjectClipboard {
    /// A raw custom type works on the general pasteboard with no UTI
    /// registration, and carries losslessly between Sketcher windows and launches.
    static let objectType = NSPasteboard.PasteboardType("com.phamqm.sketcher.objects")

    struct Payload: Codable {
        static let currentVersion = 1
        var version: Int
        var objects: [ObjectSpec]

        init(objects: [ObjectSpec]) {
            version = Payload.currentVersion
            self.objects = objects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            objects = try c.decodeIfPresent([ObjectSpec].self, forKey: .objects) ?? []
        }
    }

    // MARK: - Write

    @discardableResult
    static func write(_ objects: [DrawObject], image: CGImage?,
                      pixelsPerPoint: CGFloat) -> Bool {
        guard !objects.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var wroteAny = false

        // Lossless object JSON — the representation Sketcher reads back.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(Payload(objects: objects.map(ObjectSpec.init))) {
            wroteAny = pasteboard.setData(data, forType: objectType) || wroteAny
        }

        // Image representations for other apps.
        if let image {
            if let png = ExportService.pngData(image, pixelsPerPoint: pixelsPerPoint) {
                wroteAny = pasteboard.setData(png, forType: .png) || wroteAny
            }
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: CGFloat(image.width) / max(pixelsPerPoint, 1),
                              height: CGFloat(image.height) / max(pixelsPerPoint, 1))
            if let tiff = rep.representation(using: .tiff, properties: [:]) {
                wroteAny = pasteboard.setData(tiff, forType: .tiff) || wroteAny
            }
        }
        return wroteAny
    }

    // MARK: - Read

    /// The objects on the pasteboard, or nil if it carries no Sketcher object
    /// data. The caller assigns fresh identities when inserting.
    static func read() -> [DrawObject]? {
        guard let data = NSPasteboard.general.data(forType: objectType),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.objects.isEmpty else { return nil }
        return payload.objects.map(\.object)
    }

    static var hasObjects: Bool {
        NSPasteboard.general.data(forType: objectType) != nil
    }
}
