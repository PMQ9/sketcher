import AppKit
import UniformTypeIdentifiers

/// Getting pixels out of the app: clipboard, save panel, drag-out.
@MainActor
enum ExportCommands {

    /// ⌘C with nothing selected copies the whole canvas.
    /// (Object and region copy arrive in M3 and M7.)
    static func copyCanvas(_ viewModel: EditorViewModel) {
        _ = PasteboardWriter.writeCanvas(viewModel.scene, surfaces: viewModel.surfaces)
    }

    /// Export through an `NSSavePanel`, remembering the chosen format.
    static func exportImage(_ viewModel: EditorViewModel, in window: NSWindow?) {
        let scene = viewModel.scene
        guard let image = ExportService.renderFullResolution(scene,
                                                             surfaces: viewModel.surfaces) else {
            presentError(ImageExporter.ExportError.renderFailed, in: window)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = PasteboardWriter.timestampedName()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = ImageExporter.Format.allCases.map(\.utType)
        panel.message = "Export the canvas as an image."

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // Pick the format from the extension the user actually typed —
            // NSSavePanel lets them override the popup by editing the name.
            let ext = url.pathExtension.lowercased()
            let format = ImageExporter.Format.allCases.first { $0.fileExtension == ext }
                ?? (ext == "jpeg" ? .jpeg : .png)
            do {
                try ImageExporter.write(image, to: url, format: format,
                                        pixelsPerPoint: scene.canvas.pixelsPerPoint)
            } catch {
                presentError(error, in: window)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    /// A file URL suitable for dragging out to Finder, Slack, or a browser.
    static func dragOutURL(_ viewModel: EditorViewModel) -> URL? {
        guard let image = ExportService.renderFullResolution(viewModel.scene,
                                                             surfaces: viewModel.surfaces) else {
            return nil
        }
        return PasteboardWriter.temporaryPNG(image,
                                             pixelsPerPoint: viewModel.scene.canvas.pixelsPerPoint,
                                             name: PasteboardWriter.timestampedName())
    }

    private static func presentError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
