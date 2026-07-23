import SwiftUI

/// The layer stack: rows top-to-bottom (matching z-order on screen), each with
/// visibility and lock toggles and an editable name, plus opacity and blend for
/// the active layer and a toolbar of stack operations.
///
/// Every action routes through `EditorViewModel`'s layer API, so each is one
/// named, undoable step.
struct LayersPanel: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            // Top of the array is the top of the stack, so show it reversed.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(viewModel.layers.reversed()) { layer in
                        LayerRow(viewModel: viewModel, layer: layer,
                                 isActive: layer.id == viewModel.activeLayerID)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 180)

            if let active = viewModel.activeLayer {
                activeControls(active)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Layers").font(.headline).foregroundStyle(.secondary)
            Spacer()
            iconButton("plus.rectangle", "New Vector Layer") { viewModel.addVectorLayer() }
            iconButton("plus.square.dashed", "New Raster Layer") { viewModel.addRasterLayer() }
            iconButton("plus.square.on.square", "Duplicate Layer") { viewModel.duplicateActiveLayer() }
            iconButton("arrow.merge", "Merge Down") { viewModel.mergeDownActiveLayer() }
                .disabled(!viewModel.canMergeDown)
            iconButton("trash", "Delete Layer") { viewModel.deleteActiveLayer() }
                .disabled(viewModel.layers.count <= 1)
        }
    }

    private func activeControls(_ layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 2) {
                Text("Opacity").font(.caption)
                Spacer()
                Text("\(Int((layer.opacity * 100).rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: opacity(layer), in: 0...1) { editing in
                if editing { viewModel.beginLayerOpacityEdit() }
                else { viewModel.endLayerOpacityEdit() }
            }
            HStack(spacing: 6) {
                Picker("Blend", selection: blend(layer)) {
                    ForEach(BlendChoice.all, id: \.mode.rawValue) { choice in
                        Text(choice.name).tag(choice.mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Spacer()
                iconButton("arrow.up", "Raise") { viewModel.raiseActiveLayer() }
                iconButton("arrow.down", "Lower") { viewModel.lowerActiveLayer() }
                if layer.isVector {
                    iconButton("square.fill.on.square", "Rasterize") {
                        viewModel.rasterizeActiveLayer()
                    }
                }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func opacity(_ layer: Layer) -> Binding<Double> {
        Binding(get: { Double(layer.opacity) },
                set: { viewModel.setLayerOpacity(layer.id, CGFloat($0)) })
    }

    private func blend(_ layer: Layer) -> Binding<CGBlendMode> {
        Binding(get: { layer.blend },
                set: { viewModel.setLayerBlend(layer.id, $0) })
    }
}

/// One layer row. Rename uses a local draft committed on submit, so a rename is
/// a single undo entry rather than one per keystroke.
private struct LayerRow: View {
    @Bindable var viewModel: EditorViewModel
    let layer: Layer
    let isActive: Bool
    @State private var draftName = ""
    @State private var isRenaming = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.setLayerVisible(layer.id, !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.primary : .secondary)
            }
            .buttonStyle(.borderless)

            Image(systemName: layer.isVector ? "scribble.variable" : "photo")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { commitRename() }
            } else {
                Text(layer.name)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginRename() }
                    .onTapGesture { viewModel.setActiveLayer(layer.id) }
            }

            Button {
                viewModel.setLayerLocked(layer.id, !layer.isLocked)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(layer.isLocked ? Color.primary : .secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(isActive ? Color(nsColor: .controlAccentColor).opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.setActiveLayer(layer.id) }
    }

    private func beginRename() {
        draftName = layer.name
        isRenaming = true
    }

    private func commitRename() {
        viewModel.setLayerName(layer.id, draftName)
        isRenaming = false
    }
}

/// The user-facing blend modes, a curated subset of `CGBlendMode`.
private struct BlendChoice {
    let mode: CGBlendMode
    let name: String

    static let all: [BlendChoice] = [
        .init(mode: .normal, name: "Normal"),
        .init(mode: .multiply, name: "Multiply"),
        .init(mode: .screen, name: "Screen"),
        .init(mode: .overlay, name: "Overlay"),
        .init(mode: .darken, name: "Darken"),
        .init(mode: .lighten, name: "Lighten"),
        .init(mode: .difference, name: "Difference"),
    ]
}
