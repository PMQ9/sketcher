import AppKit

/// Font-panel plumbing, kept out of the view model so the view model stays
/// AppKit-free (mirrors `ColorCommands`).
///
/// The panel sends `changeFont:` up the responder chain: to the `TextSinkView`
/// while editing, or to `EditorWindowController` when a text object is merely
/// selected. Both convert the current font and call `applyTextFont`.
@MainActor
enum FontCommands {
    static func showFontPanel(_ viewModel: EditorViewModel) {
        let manager = NSFontManager.shared
        let seed = NSFont(name: viewModel.textFontName, size: viewModel.textFontSizePx)
            ?? .systemFont(ofSize: viewModel.textFontSizePx)
        manager.setSelectedFont(seed, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }
}
