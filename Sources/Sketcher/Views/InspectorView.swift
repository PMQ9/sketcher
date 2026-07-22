import SwiftUI

/// The style inspector. Edits the selected objects' style when there is a
/// selection, and the armed-tool defaults otherwise — so the same panel answers
/// "how will the next shape look" and "restyle these shapes".
///
/// Slider drags are bracketed by `beginStyleEdit`/`endStyleEdit`, so dragging
/// stroke width across 40 values is ONE undo entry, not 40.
struct InspectorView: View {
    @Bindable var viewModel: EditorViewModel

    private var ppp: CGFloat { viewModel.scene.canvas.pixelsPerPoint }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if viewModel.hasEditableText { textSection }
                fillSection
                strokeSection
                if viewModel.inspectorHasRect { cornerSection }
                opacitySection
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    private var header: some View {
        Text(viewModel.selection.hasObjects
             ? "^[\(viewModel.selection.objectIDs.count) object](inflect: true) selected"
             : "Tool Defaults")
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    // MARK: - Sections

    private var fillSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Fill", isOn: fillEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
            if viewModel.inspectorStyle.fill.isVisible {
                ColorPicker("Fill Color", selection: fillColor, supportsOpacity: true)
                    .labelsHidden()
            }
        }
    }

    private var strokeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("Stroke Width", value: strokeWidth, range: 0...64,
                   display: "\(Int((viewModel.inspectorStyle.strokeWidthPx / ppp).rounded())) pt",
                   name: "Stroke Width")
            Picker("Dash", selection: dash) {
                Text("Solid").tag(DashStyle.solid)
                Text("Dashed").tag(DashStyle.dashed)
                Text("Dotted").tag(DashStyle.dotted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    /// Text controls: size, weight/slant/underline, alignment, line height, and
    /// the legibility plate. Shown whenever text is being edited or selected.
    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text").font(.caption).foregroundStyle(.secondary)

            slider("Font Size", value: fontSize, range: 6...400,
                   display: "\(Int(fontSizeDisplayPt.rounded())) pt", name: "Font Size")

            HStack(spacing: 4) {
                styleToggle("bold", isOn: currentBold) { viewModel.toggleTextBold() }
                styleToggle("italic", isOn: currentItalic) { viewModel.toggleTextItalic() }
                styleToggle("underline", isOn: currentUnderline) { viewModel.toggleTextUnderline() }
                Spacer()
            }

            Picker("Text Alignment", selection: textAlignment) {
                Image(systemName: "text.alignleft").tag(TextAlignment.left)
                Image(systemName: "text.aligncenter").tag(TextAlignment.center)
                Image(systemName: "text.alignright").tag(TextAlignment.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            slider("Line Height", value: lineHeight, range: 0.8...3.0,
                   display: String(format: "%.1f\u{00D7}", currentLineHeight), name: "Line Height")

            Toggle("Legibility Plate", isOn: plateEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
        }
    }

    private func styleToggle(_ symbol: String, isOn: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 20)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(isOn ? Color(nsColor: .controlAccentColor).opacity(0.22) : .clear))
        .foregroundStyle(isOn ? Color(nsColor: .controlAccentColor) : Color.primary)
    }

    private var cornerSection: some View {
        slider("Corner Radius", value: corner, range: 0...200,
               display: "\(Int((viewModel.inspectorCornerRadiusPx / ppp).rounded())) pt",
               name: "Corner Radius")
    }

    private var opacitySection: some View {
        slider("Opacity", value: opacity, range: 0...1,
               display: "\(Int((viewModel.inspectorStyle.opacity * 100).rounded()))%",
               name: "Opacity")
    }

    /// A labeled slider that coalesces its drag into one undo entry.
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, display: String,
                        name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(display).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if editing { viewModel.beginStyleEdit() } else { viewModel.endStyleEdit(name) }
            }
        }
    }

    // MARK: - Bindings

    private var strokeWidth: Binding<Double> {
        Binding(get: { Double(viewModel.inspectorStyle.strokeWidthPx / ppp) },
                set: { viewModel.setStrokeWidthPx(viewModel.scene.canvas.px(fromPoints: CGFloat($0))) })
    }

    private var opacity: Binding<Double> {
        Binding(get: { Double(viewModel.inspectorStyle.opacity) },
                set: { viewModel.setOpacity(CGFloat($0)) })
    }

    private var corner: Binding<Double> {
        Binding(get: { Double(viewModel.inspectorCornerRadiusPx / ppp) },
                set: { viewModel.setCornerRadiusPx(viewModel.scene.canvas.px(fromPoints: CGFloat($0))) })
    }

    private var fillEnabled: Binding<Bool> {
        Binding(get: { viewModel.inspectorStyle.fill.isVisible },
                set: { viewModel.setFillEnabled($0) })
    }

    private var fillColor: Binding<Color> {
        Binding(get: { Color(viewModel.inspectorStyle.fill.color ?? viewModel.primaryColor) },
                set: { viewModel.setFillColor(RGBAColor($0)) })
    }

    private var dash: Binding<DashStyle> {
        Binding(get: { viewModel.inspectorStyle.dash },
                set: { viewModel.setDash($0) })
    }

    // MARK: - Text bindings

    /// The text object being edited or selected, whose attributes drive display.
    private var textPayload: TextPayload? { viewModel.representativeTextPayload }

    private var currentBold: Bool { textPayload?.isBold ?? viewModel.textBold }
    private var currentItalic: Bool { textPayload?.isItalic ?? viewModel.textItalic }
    private var currentUnderline: Bool { textPayload?.isUnderlined ?? viewModel.textUnderlined }
    private var currentLineHeight: CGFloat {
        textPayload?.lineHeightMultiple ?? viewModel.textLineHeightMultiple
    }
    private var fontSizeDisplayPt: CGFloat {
        (textPayload?.fontSizePx ?? viewModel.textFontSizePx) / ppp
    }

    private var fontSize: Binding<Double> {
        Binding(get: { Double(fontSizeDisplayPt) },
                set: { viewModel.setTextFontSize(viewModel.scene.canvas.px(fromPoints: CGFloat($0))) })
    }

    private var lineHeight: Binding<Double> {
        Binding(get: { Double(currentLineHeight) },
                set: { viewModel.setTextLineHeight(CGFloat($0)) })
    }

    private var textAlignment: Binding<TextAlignment> {
        Binding(get: { textPayload?.alignment ?? viewModel.textAlignment },
                set: { viewModel.setTextAlignment($0) })
    }

    private var plateEnabled: Binding<Bool> {
        Binding(get: { textPayload?.plateColor != nil },
                set: { _ in viewModel.toggleTextPlate() })
    }
}
