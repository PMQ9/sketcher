import AppKit
import Foundation

/// The one place a `Command` turns into a mutation.
@MainActor
enum CommandDispatch {
    static func perform(_ command: Command, on viewModel: EditorViewModel) {
        switch command {
        case .undo: viewModel.undo()
        case .redo: viewModel.redo()
        case .delete: viewModel.deleteSelection()
        case .selectAll: viewModel.selectAll()
        case .deselect: viewModel.escape()
        case .copyCanvas: ExportCommands.copyCanvas(viewModel)
        case .exportImage:
            ExportCommands.exportImage(viewModel, in: NSApp.keyWindow)

        case .toolSelect: viewModel.tool = .select
        case .toolBrush: viewModel.tool = .brush
        case .toolEraser: viewModel.tool = .eraser
        case .toolRectangle: viewModel.tool = .rectangle
        case .toolEllipse: viewModel.tool = .ellipse
        case .toolLine: viewModel.tool = .line
        case .toolArrow: viewModel.tool = .arrow
        case .toolPolygon: viewModel.tool = .polygon
        case .toolHand: viewModel.tool = .hand
        case .toolZoom: viewModel.tool = .zoom

        case .backgroundLight: viewModel.setCanvasBackground(.light)
        case .backgroundDark: viewModel.setCanvasBackground(.dark)
        case .backgroundTransparent: viewModel.setCanvasBackground(.transparent)
        case .toggleCanvasMode:
            viewModel.setCanvasMode(
                viewModel.scene.canvas.mode == .contained ? .infinite : .contained)

        case .zoomIn:
            viewModel.zoom(by: 1.25, about: viewModel.viewportCenter)
        case .zoomOut:
            viewModel.zoom(by: 1 / 1.25, about: viewModel.viewportCenter)
        case .zoomActualSize: viewModel.zoomToActualSize()
        case .zoomToFit: viewModel.zoomToFit()

        case .brushSizeDown: viewModel.adjustBrushSize(step: -1)
        case .brushSizeUp: viewModel.adjustBrushSize(step: 1)
        }
    }

    /// Whether the command should appear enabled. Drives `NSMenuItem`
    /// validation, so greyed-out menu items match what actually works.
    static func isEnabled(_ command: Command, for viewModel: EditorViewModel) -> Bool {
        switch command {
        case .undo: return viewModel.canUndo || viewModel.isGestureInFlight
        case .redo: return viewModel.canRedo
        case .delete: return viewModel.selection.hasObjects
        case .deselect: return !viewModel.selection.isEmpty
        default: return true
        }
    }
}

@MainActor
extension EditorViewModel {
    var viewportCenter: CGPoint {
        CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    var isGestureInFlight: Bool { history.isGestureInFlight }
}
