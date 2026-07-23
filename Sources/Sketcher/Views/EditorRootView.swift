import SwiftUI

/// Window content: toolbar over canvas, a style inspector on the trailing edge,
/// and a status strip along the bottom.
struct EditorRootView: View {
    @Bindable var viewModel: EditorViewModel
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(viewModel: viewModel)
            Divider()
            HStack(spacing: 0) {
                CanvasView(viewModel: viewModel)
                    .frame(minWidth: 480, minHeight: 320)
                if showInspector {
                    Divider()
                    VStack(spacing: 0) {
                        InspectorView(viewModel: viewModel)
                        Divider()
                        LayersPanel(viewModel: viewModel)
                    }
                    .frame(width: 216)
                    .transition(.move(edge: .trailing))
                }
            }
            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label {
                Text("\(viewModel.scene.canvas.pixelSize.width) × \(viewModel.scene.canvas.pixelSize.height)")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "rectangle.dashed")
            }

            Divider().frame(height: 12)

            Button {
                viewModel.setCanvasMode(
                    viewModel.scene.canvas.mode == .contained ? .infinite : .contained)
            } label: {
                Label(viewModel.scene.canvas.mode == .contained ? "Contained" : "Infinite",
                      systemImage: viewModel.scene.canvas.mode == .contained
                          ? "rectangle.inset.filled"
                          : "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
            }
            .buttonStyle(.borderless)
            .help("Contained clips to the page. Infinite pans freely and keeps content outside it. Export uses the page either way.")

            Spacer()

            Text(viewModel.tool.displayName)
                .foregroundStyle(.secondary)

            Divider().frame(height: 12)

            Button {
                withAnimation(.easeOut(duration: 0.15)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .help("Toggle the style inspector")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
