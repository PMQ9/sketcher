import AppKit

/// The text-editing input sink (M5).
///
/// This is an `NSTextView` used PURELY as an IME / dictation / spellcheck /
/// caret sink — its own glyphs are drawn in clear, because CoreText draws the
/// visible text through the shared renderer (invariant T14). Letting TextKit lay
/// out visible glyphs would produce a reflow pop at commit, since TextKit 2 and
/// `CTFramesetter` disagree on line breaking and last-line rounding.
///
/// It reports every string change back through `onEdit`, so the payload updates
/// and CoreText redraws live. It commits on ⌘Return / Esc (`onCommit`) and on
/// losing focus (`onResign`, e.g. clicking away). The font panel routes
/// `changeFont:` here because the sink is first responder while editing.
@MainActor
final class TextSinkView: NSTextView {
    var onEdit: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onResign: (() -> Void)?
    var onFont: ((NSFont) -> Void)?

    /// Build a configured sink. `NSTextView(frame:)` wires up a default text
    /// container; the rest turns it into an invisible input surface.
    static func make() -> TextSinkView {
        let view = TextSinkView(frame: .zero)
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.isFieldEditor = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // Glyphs invisible: CoreText owns the visible text. The caret stays
        // visible via `insertionPointColor`, set per-object on sync.
        view.textColor = .clear
        return view
    }

    // MARK: - Reporting

    override func didChangeText() {
        super.didChangeText()
        onEdit?(string)
    }

    /// Losing first-responder status (clicking away, switching windows) commits.
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onResign?() }
        return ok
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        // ⌘Return commits; Return alone inserts a newline (this is multiline).
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Esc commits (keeping the text), rather than beeping.
    override func cancelOperation(_ sender: Any?) {
        onCommit?()
    }

    // MARK: - Font panel

    override func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else {
            super.changeFont(sender)
            return
        }
        let current = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let converted = manager.convert(current)
        font = converted
        onFont?(converted)
    }

    // MARK: - Attribute construction

    /// An `NSFont` matching the payload at the given view scale (view points per
    /// canvas pixel), so the caret and IME geometry line up with the CoreText
    /// glyphs drawn underneath.
    static func font(for payload: TextPayload, scale: CGFloat) -> NSFont {
        let size = max(payload.fontSizePx * scale, 1)
        let base = NSFont(name: payload.fontName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if payload.isBold { traits.insert(.boldFontMask) }
        if payload.isItalic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }
}

extension TextAlignment {
    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }
}

extension RGBAColor {
    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension NSFont {
    func hasTrait(_ trait: NSFontTraitMask) -> Bool {
        NSFontManager.shared.traits(of: self).contains(trait)
    }
}
