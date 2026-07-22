import AppKit
import CoreGraphics

/// Writing images to the system pasteboard.
///
/// Writes BOTH PNG and TIFF: some paste targets accept only one, and which one
/// is not predictable from the app. PNG carries alpha and is what most modern
/// targets prefer; TIFF is what older AppKit-based targets ask for.
enum PasteboardWriter {

    @discardableResult
    static func write(_ image: CGImage, pixelsPerPoint: CGFloat) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let rep = NSBitmapImageRep(cgImage: image)
        // Set the POINT size, not the pixel size. Without this a 2x canvas
        // pastes in at double its intended dimensions everywhere.
        rep.size = NSSize(width: CGFloat(image.width) / max(pixelsPerPoint, 1),
                          height: CGFloat(image.height) / max(pixelsPerPoint, 1))

        var wroteAny = false
        if let png = ExportService.pngData(image, pixelsPerPoint: pixelsPerPoint) {
            wroteAny = pasteboard.setData(png, forType: .png) || wroteAny
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            wroteAny = pasteboard.setData(tiff, forType: .tiff) || wroteAny
        }
        return wroteAny
    }

    /// Render the scene and put it on the pasteboard.
    @discardableResult
    static func writeCanvas(_ scene: Scene, surfaces: SurfaceStore) -> Bool {
        guard let image = ExportService.renderFullResolution(scene, surfaces: surfaces) else {
            return false
        }
        return write(image, pixelsPerPoint: scene.canvas.pixelsPerPoint)
    }

    /// A temporary PNG on disk, for drag-out. Finder requires a file URL, and
    /// Slack and browsers accept one too.
    static func temporaryPNG(_ image: CGImage, pixelsPerPoint: CGFloat,
                             name: String) -> URL? {
        guard let data = ExportService.pngData(image, pixelsPerPoint: pixelsPerPoint) else {
            return nil
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sketcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Filenames use a POSIX locale explicitly — otherwise a user's calendar or
    /// 12-hour clock setting mangles them.
    static func timestampedName(prefix: String = "Sketch") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: Date()))"
    }
}
