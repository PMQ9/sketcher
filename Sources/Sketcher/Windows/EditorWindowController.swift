import AppKit
import SwiftUI

/// Hosts the SwiftUI editor in a plain `NSWindow`.
@MainActor
final class EditorWindowController: NSWindowController, NSMenuItemValidation {
    private let viewModel: EditorViewModel

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel

        let hosting = NSHostingView(rootView: EditorRootView(viewModel: viewModel))
        // Drives the window's minimum size from the SwiftUI content, so the
        // window can never be dragged narrower than the most collapsed
        // `ViewThatFits` toolbar layout. Non-obvious and load-bearing.
        hosting.sizingOptions = [.minSize]

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let initialSize = CGSize(width: min(1200, screen.width * 0.8),
                                 height: min(820, screen.height * 0.85))

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        window.title = "Untitled"
        // NSDocument owns the lifecycle; releasing on close would pull the rug
        // out from under it.
        window.isReleasedWhenClosed = false
        // Cocoa window restoration would reopen last session's UNTITLED windows
        // as blank canvases, competing with the scratch recovery that actually
        // preserves content. One recovery mechanism, not two.
        window.isRestorable = false
        window.center()

        super.init(window: window)
        window.makeFirstResponder(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Undo

    // The responder chain hands `undo:` / `redo:` to an `NSUndoManager` this app
    // does not drive, which would silently make ⌘Z dead. Routing through custom
    // selectors keeps the snapshot stacks authoritative.

    @objc func performUndo(_ sender: Any?) {
        viewModel.undo()
    }

    @objc func performRedo(_ sender: Any?) {
        viewModel.redo()
    }

    @objc func performSketcherCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let command = item.sketcherCommand else { return }
        CommandDispatch.perform(command, on: viewModel)
    }

    /// The font panel sends `changeFont:` up the responder chain. While editing
    /// the `TextSinkView` (earlier in the chain) handles it; when a text object
    /// is merely selected it reaches here and restyles the selection.
    @objc func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return }
        let current = NSFont(name: viewModel.textFontName, size: viewModel.textFontSizePx)
            ?? .systemFont(ofSize: viewModel.textFontSizePx)
        let converted = manager.convert(current)
        viewModel.applyTextFont(name: converted.fontName, sizePx: converted.pointSize,
                                bold: converted.hasTrait(.boldFontMask),
                                italic: converted.hasTrait(.italicFontMask))
    }

    /// Object-editing commands whose ⌘-key equivalents must NOT fire while a text
    /// field editor owns the keyboard — otherwise ⌘V would paste objects onto the
    /// text being typed. Disabling them lets the event fall to the field editor.
    private static let fieldEditorBlocked: Set<Command> =
        [.cut, .copy, .paste, .pasteInPlace, .duplicate, .delete, .selectAll]

    private var isFieldEditorActive: Bool { window?.firstResponder is NSText }

    /// `NSWindowController` does not implement menu validation itself, so this
    /// conforms to `NSMenuItemValidation` rather than overriding.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.sketcherCommand else { return true }
        if isFieldEditorActive, Self.fieldEditorBlocked.contains(command) { return false }
        return CommandDispatch.isEnabled(command, for: viewModel)
    }
}
