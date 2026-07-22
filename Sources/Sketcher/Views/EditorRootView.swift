import SwiftUI

/// Window content: toolbar over canvas, with a status strip along the bottom.
struct EditorRootView: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(viewModel: viewModel)
            Divider()
            CanvasView(viewModel: viewModel)
                .frame(minWidth: 480, minHeight: 320)
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
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
