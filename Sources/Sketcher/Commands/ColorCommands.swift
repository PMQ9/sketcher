import AppKit

/// Color actions that need AppKit, kept out of the view model so it stays
/// UI-framework-agnostic.
@MainActor
enum ColorCommands {
    /// The screen-wide eyedropper. `NSColorSampler` needs no TCC prompt — the
    /// whole reason v1 uses it instead of screen capture (D10).
    static func pickScreenColor(_ viewModel: EditorViewModel) {
        NSColorSampler().show { nsColor in
            guard let ns = nsColor?.usingColorSpace(.sRGB) else { return }
            let color = RGBAColor(r: ns.redComponent, g: ns.greenComponent,
                                  b: ns.blueComponent, a: ns.alphaComponent)
            // NSColorSampler fires its completion on the main thread.
            MainActor.assumeIsolated { viewModel.armColor(color) }
        }
    }
}
