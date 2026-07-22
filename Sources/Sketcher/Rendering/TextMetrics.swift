import CoreGraphics
import CoreText
import Foundation

/// CoreText measurement and drawing.
///
/// INVARIANT: text is ALWAYS laid out and drawn by CoreText, on screen and in
/// export alike. M5 adds an `NSTextView` overlay for editing, but that view is
/// an IME/dictation input sink with its own drawing disabled — letting it lay
/// out produces a visible reflow pop at commit, because TextKit 2 and
/// `CTFramesetter` disagree on line breaking and last-line rounding.
enum TextMetrics {
    static func font(for payload: TextPayload) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if payload.isBold { traits.insert(.traitBold) }
        if payload.isItalic { traits.insert(.traitItalic) }

        let base = CTFontCreateWithName(payload.fontName as CFString,
                                        payload.fontSizePx, nil)
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, payload.fontSizePx, nil,
                                                  traits, traits) ?? base
    }

    static func attributedString(_ payload: TextPayload,
                                 color: CGColor) -> CFAttributedString {
        let ctFont = font(for: payload)

        var alignment: CTTextAlignment
        switch payload.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        case .justified: alignment = .justified
        }

        var lineHeightMultiple = payload.lineHeightMultiple

        // The setting structs hold raw pointers into these locals, so the
        // pointers must outlive CTParagraphStyleCreate — passing `&alignment`
        // inline yields a pointer valid only for the duration of the
        // CTParagraphStyleSetting initializer, which is a dangling read.
        let paragraph = withUnsafePointer(to: &alignment) { alignmentPtr in
            withUnsafePointer(to: &lineHeightMultiple) { lineHeightPtr in
                var settings = [
                    CTParagraphStyleSetting(spec: .alignment,
                                            valueSize: MemoryLayout<CTTextAlignment>.size,
                                            value: alignmentPtr),
                    CTParagraphStyleSetting(spec: .lineHeightMultiple,
                                            valueSize: MemoryLayout<CGFloat>.size,
                                            value: lineHeightPtr)
                ]
                return CTParagraphStyleCreate(&settings, settings.count)
            }
        }

        var attributes: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: paragraph
        ]
        if payload.isUnderlined {
            attributes[kCTUnderlineStyleAttributeName] =
                CTUnderlineStyle.single.rawValue
        }

        return CFAttributedStringCreate(nil, payload.string as CFString,
                                        attributes as CFDictionary)
    }

    private static let unbounded = CGFloat.greatestFiniteMagnitude

    /// Laid-out size for the payload's sizing mode. Auto-width measures the
    /// longest line; auto-height wraps to `boxSize.width`; fixed uses the box.
    static func layoutSize(of payload: TextPayload) -> CGSize {
        guard !payload.string.isEmpty else {
            // An empty box still needs a caret-height footprint, or a freshly
            // placed text object has zero bounds and cannot be selected.
            return CGSize(width: payload.fontSizePx * 0.6, height: payload.fontSizePx * 1.2)
        }

        if payload.resize == .fixed, let box = payload.boxSize { return box }

        let constraint: CGSize
        switch payload.resize {
        case .autoWidth:
            constraint = CGSize(width: unbounded, height: unbounded)
        case .autoHeight:
            constraint = CGSize(width: payload.boxSize?.width ?? unbounded,
                                height: unbounded)
        case .fixed:
            constraint = payload.boxSize ?? CGSize(width: unbounded, height: unbounded)
        }

        let attributed = attributedString(payload, color: RGBAColor.black.cgColor)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)

        // CTFramesetter under-reports by a sub-point amount on the last line;
        // ceil so the drawn glyphs never spill outside the reported bounds.
        return CGSize(width: ceil(fitted.width) + 1, height: ceil(fitted.height) + 1)
    }

    static func bounds(of payload: TextPayload) -> CGRect {
        CGRect(origin: payload.origin, size: layoutSize(of: payload))
    }

    /// Draw into a y-DOWN context (the renderer's contract). CoreText is y-up,
    /// so this flips locally around the text box — the flip is contained here
    /// and must not leak into the caller.
    static func draw(_ payload: TextPayload, color: CGColor, in ctx: CGContext) {
        guard !payload.string.isEmpty else { return }
        let box = bounds(of: payload)

        if let plate = payload.plateColor {
            ctx.saveGState()
            ctx.setFillColor(plate.cgColor)
            ctx.fill(box.insetBy(dx: -payload.fontSizePx * 0.15,
                                 dy: -payload.fontSizePx * 0.08))
            ctx.restoreGState()
        }

        let attributed = attributedString(payload, color: color)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter,
                                             CFRange(location: 0, length: 0), path, nil)

        ctx.saveGState()
        ctx.translateBy(x: box.minX, y: box.minY + box.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
