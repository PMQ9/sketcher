import AppKit
import SwiftUI

/// Tool palette and quick controls.
///
/// Uses `ViewThatFits` so the toolbar degrades to progressively more compact
/// layouts instead of clipping. Paired with `sizingOptions = [.minSize]` on the
/// hosting view, the window can never be dragged narrower than the most
/// collapsed layout.
struct ToolbarView: View {
    @Bindable var viewModel: EditorViewModel

    /// M1 ships the tools that actually work. The rest arrive with their
    /// milestones rather than appearing as dead buttons.
    private static let availableTools: [Tool] = [
        .select, .brush, .eraser, .rectangle, .ellipse, .line, .arrow, .polygon, .hand
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showLabels: true)
            row(showLabels: false)
            compactRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func row(showLabels: Bool) -> some View {
        HStack(spacing: 10) {
            toolCluster
            Divider().frame(height: 20)
            colorAndWidth
            Divider().frame(height: 20)
            backgroundPicker(showLabels: showLabels)
            Spacer(minLength: 8)
            historyCluster
            Divider().frame(height: 20)
            zoomCluster
        }
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            toolCluster
            Divider().frame(height: 20)
            colorWell
            Spacer(minLength: 4)
            historyCluster
        }
    }

    // MARK: - Clusters

    private var toolCluster: some View {
        HStack(spacing: 2) {
            ForEach(Self.availableTools, id: \.self) { tool in
                Button {
                    viewModel.tool = tool
                } label: {
                    Image(systemName: tool.symbolName)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(viewModel.tool == tool
                              ? Color(nsColor: .controlAccentColor).opacity(0.22)
                              : .clear)
                )
                .foregroundStyle(viewModel.tool == tool
                                 ? Color(nsColor: .controlAccentColor)
                                 : Color.primary)
                .help("\(tool.displayName)  \(shortcutHint(for: tool))")
            }
        }
    }

    private var colorAndWidth: some View {
        HStack(spacing: 8) {
            colorWell
            Slider(value: strokeWidthPoints, in: 1...64) {
                Text("Size")
            }
            .frame(width: 90)
            .help("Stroke width")
            Text("\(Int(viewModel.brush.sizePx / viewModel.scene.canvas.pixelsPerPoint))")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
        }
    }

    private var colorWell: some View {
        ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
            .labelsHidden()
            .help("Stroke color")
    }

    private func backgroundPicker(showLabels: Bool) -> some View {
        Picker("Canvas", selection: backgroundBinding) {
            Label("Light", systemImage: "sun.max").tag(BackgroundChoice.light)
            Label("Dark", systemImage: "moon").tag(BackgroundChoice.dark)
            Label("Transparent", systemImage: "square.grid.3x3").tag(BackgroundChoice.transparent)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: showLabels ? 150 : 110)
        .help("Canvas background")
    }

    private var historyCluster: some View {
        HStack(spacing: 2) {
            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            .help(viewModel.history.undoActionName.map { "Undo \($0)" } ?? "Undo")

            Button { viewModel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)
            .help(viewModel.history.redoActionName.map { "Redo \($0)" } ?? "Redo")
        }
        .buttonStyle(.borderless)
    }

    private var zoomCluster: some View {
        HStack(spacing: 6) {
            Button { viewModel.zoomToFit() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Zoom to Fit  ⌘1")

            Button { viewModel.zoomToActualSize() } label: {
                Text("\(Int((viewModel.transform.scale * viewModel.scene.canvas.pixelsPerPoint) * 100))%")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 44)
            }
            .buttonStyle(.borderless)
            .help("Actual Size  ⌘0")
        }
    }

    // MARK: - Bindings

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(viewModel.primaryColor) },
            set: { viewModel.primaryColor = RGBAColor($0) }
        )
    }

    /// Stroke width is point-denominated in the UI and converted to pixels at
    /// this boundary — the model never stores points.
    private var strokeWidthPoints: Binding<Double> {
        Binding(
            get: { Double(viewModel.brush.sizePx / viewModel.scene.canvas.pixelsPerPoint) },
            set: {
                let px = viewModel.scene.canvas.px(fromPoints: CGFloat($0))
                viewModel.brush.sizePx = px
                viewModel.style.strokeWidthPx = px
            }
        )
    }

    private var backgroundBinding: Binding<BackgroundChoice> {
        Binding(
            get: { BackgroundChoice(viewModel.scene.canvas.background) },
            set: { viewModel.setCanvasBackground($0.background) }
        )
    }

    private func shortcutHint(for tool: Tool) -> String {
        KeyMap.toolKeys.first { $0.value == tool }?.key.uppercased() ?? ""
    }
}

enum BackgroundChoice: Hashable {
    case light, dark, transparent

    init(_ background: CanvasBackground) {
        switch background {
        case .transparent: self = .transparent
        case .solid(let c): self = c.luminance < 0.5 ? .dark : .light
        }
    }

    var background: CanvasBackground {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .transparent: return .transparent
        }
    }
}

// MARK: - Color bridging

extension Color {
    init(_ rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

extension RGBAColor {
    /// Convert through sRGB explicitly: `NSColorPanel` hands back a color in
    /// whatever space its current tab uses, and using it unconverted shifts
    /// every painted color.
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: ns.redComponent, g: ns.greenComponent,
                  b: ns.blueComponent, a: ns.alphaComponent)
    }
}
