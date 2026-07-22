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
}
