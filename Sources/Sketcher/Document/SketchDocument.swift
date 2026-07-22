import AppKit
import SwiftUI

/// One open document.
///
/// `NSDocument` (rather than a hand-rolled window) buys Open Recent, autosave
/// in place, Versions, the edited dot, save-on-quit, and native window tabs for
/// roughly the code below.
///
/// The `@objc` name is mandatory: `NSDocumentClass` in Info.plist cannot
/// resolve a Swift class through SwiftPM's module mangling without it.
@objc(SketchDocument)
@MainActor
final class SketchDocument: NSDocument {
    private(set) var viewModel: EditorViewModel

    static let typeName = "com.phamqm.sketcher.document"

    override init() {
        viewModel = EditorViewModel(scene: .blank())
        super.init()
        wireChangeTracking()
    }

    override class var autosavesInPlace: Bool { true }

    // MARK: - Change tracking

    private func wireChangeTracking() {
        viewModel.onChange = { [weak self] kind in
            guard let self else { return }
            // No hand-rolled crash recovery here. `autosavesInPlace` covers
            // UNTITLED documents too on modern AppKit: they are autosaved to
            // ~/Library/Autosave Information and reopened on the next launch,
            // which survives kill -9. See PROGRESS.md B6.
            switch kind {
            case .done: updateChangeCount(.changeDone)
            // Undoing back to the last-saved state must CLEAR the edited dot,
            // which only `.changeUndone` does — `.changeDone` would leave the
            // document permanently dirty.
            case .undone: updateChangeCount(.changeUndone)
            case .redone: updateChangeCount(.changeRedone)
            case .cleared: updateChangeCount(.changeCleared)
            }
        }
    }

    // MARK: - Windows

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(viewModel: viewModel))
    }

    // MARK: - Reading and writing

    override func data(ofType typeName: String) throws -> Data {
        try SceneCodec.encode(viewModel.scene)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        // `NSDocument.read` is nonisolated in the SDK, so this override is too
        // regardless of the class annotation. Decoding is nonisolated pure data
        // work; applying it touches the main-actor view model.
        //
        // `assumeIsolated` is sound here because `readingConcurrently` is false
        // by default, so AppKit calls this on the main thread. If concurrent
        // reading is ever enabled, this must become an async hop.
        let scene = try SceneCodec.decode(data)
        MainActor.assumeIsolated {
            viewModel.replaceScene(scene)
        }
    }

    // MARK: - Menu validation

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // While a text field owns the keyboard, Delete belongs to the field
        // editor — hijacking it would make Backspace destroy the selected
        // object instead of a character.
        if menuItem.action == #selector(NSText.delete(_:)),
           windowForSheet?.firstResponder is NSText {
            return false
        }
        if let command = menuItem.sketcherCommand {
            return CommandDispatch.isEnabled(command, for: viewModel)
        }
        return super.validateMenuItem(menuItem)
    }
}


