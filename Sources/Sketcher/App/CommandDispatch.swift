import AppKit
import Foundation

/// The one place a `Command` turns into a mutation.
@MainActor
enum CommandDispatch {
    static func perform(_ command: Command, on viewModel: EditorViewModel) {
        switch command {
        case .undo: viewModel.undo()
        case .redo: viewModel.redo()
        case .cut: viewModel.cut()
        case .copy:
            // Context-sensitive, like every editor: selected objects, else the
            // pixel region, else the whole canvas as an image.
            if viewModel.selection.hasObjects { viewModel.copySelection() }
            else if viewModel.selection.hasRegion { viewModel.copyPixelSelection() }
            else { ExportCommands.copyCanvas(viewModel) }
        case .paste: viewModel.paste()
        case .pasteInPlace: viewModel.pasteInPlace()
        case .duplicate: viewModel.duplicateSelection()
        case .delete: viewModel.deleteSelection()
        case .selectAll:
            // Context-sensitive, one keystroke apart: a pixel tool selects the
            // whole canvas region; every other tool selects all objects.
            if [.marquee, .lasso, .wand, .bucket].contains(viewModel.tool) {
                viewModel.selectAllPixels()
            } else {
                viewModel.selectAll()
            }
        case .deselect: viewModel.escape()
        case .exportImage:
            ExportCommands.exportImage(viewModel, in: NSApp.keyWindow)

        case .invertSelection: viewModel.invertSelection()
        case .growSelection: viewModel.growSelection()
        case .shrinkSelection: viewModel.shrinkSelection()
        case .featherSelection: viewModel.featherSelection()
        case .fillWithPrimary: viewModel.fillSelection(with: viewModel.primaryColor)
        case .fillWithSecondary: viewModel.fillSelection(with: viewModel.secondaryColor)

        case .bringForward: viewModel.bringForward()
        case .sendBackward: viewModel.sendBackward()
        case .bringToFront: viewModel.bringToFront()
        case .sendToBack: viewModel.sendToBack()
        case .group: viewModel.groupSelection()
        case .ungroup: viewModel.ungroupSelection()
        case .alignLeft: viewModel.alignSelection(.left)
        case .alignHCenter: viewModel.alignSelection(.hCenter)
        case .alignRight: viewModel.alignSelection(.right)
        case .alignTop: viewModel.alignSelection(.top)
        case .alignVCenter: viewModel.alignSelection(.vCenter)
        case .alignBottom: viewModel.alignSelection(.bottom)
        case .distributeHorizontally: viewModel.distributeSelection(.horizontal)
        case .distributeVertically: viewModel.distributeSelection(.vertical)
        case .toggleLock: viewModel.toggleLockSelection()
        case .toggleHidden: viewModel.toggleHiddenSelection()

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
        case .toolEyedropper: viewModel.tool = .eyedropper
        case .toolRedact: viewModel.tool = .redact
        case .toolMarquee: viewModel.tool = .marquee
        case .toolLasso: viewModel.tool = .lasso
        case .toolWand: viewModel.tool = .wand
        case .toolBucket: viewModel.tool = .bucket

        case .swapColors: viewModel.swapColors()
        case .resetColors: viewModel.resetColors()
        case .screenEyedropper: ColorCommands.pickScreenColor(viewModel)

        case .fontPanel: FontCommands.showFontPanel(viewModel)
        case .textBold: viewModel.toggleTextBold()
        case .textItalic: viewModel.toggleTextItalic()
        case .textUnderline: viewModel.toggleTextUnderline()
        case .textAlignLeft: viewModel.setTextAlignment(.left)
        case .textAlignCenter: viewModel.setTextAlignment(.center)
        case .textAlignRight: viewModel.setTextAlignment(.right)
        case .textPlate: viewModel.toggleTextPlate()

        case .backgroundLight: viewModel.setCanvasBackground(.light)
        case .backgroundDark: viewModel.setCanvasBackground(.dark)
        case .backgroundTransparent: viewModel.setCanvasBackground(.transparent)
        case .toggleCanvasMode:
            viewModel.setCanvasMode(
                viewModel.scene.canvas.mode == .contained ? .infinite : .contained)

        case .newLayer: viewModel.addVectorLayer()
        case .newRasterLayer: viewModel.addRasterLayer()
        case .duplicateLayer: viewModel.duplicateActiveLayer()
        case .deleteLayer: viewModel.deleteActiveLayer()
        case .mergeDown: viewModel.mergeDownActiveLayer()
        case .flattenImage: viewModel.flattenImage()
        case .rasterizeLayer: viewModel.rasterizeActiveLayer()
        case .raiseLayer: viewModel.raiseActiveLayer()
        case .lowerLayer: viewModel.lowerActiveLayer()

        case .zoomIn:
            viewModel.zoom(by: 1.25, about: viewModel.viewportCenter)
        case .zoomOut:
            viewModel.zoom(by: 1 / 1.25, about: viewModel.viewportCenter)
        case .zoomActualSize: viewModel.zoomToActualSize()
        case .zoomToFit: viewModel.zoomToFit()
        case .toggleAntialias: viewModel.toggleAntialias()

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
        case .duplicate: return viewModel.selection.hasObjects
        case .cut, .delete:
            return viewModel.selection.hasObjects || viewModel.selection.hasRegion
        case .paste, .pasteInPlace: return ObjectClipboard.hasObjects || ObjectClipboard.hasImage
        case .deselect: return !viewModel.selection.isEmpty
        case .invertSelection, .growSelection, .shrinkSelection, .featherSelection,
             .fillWithPrimary, .fillWithSecondary:
            return viewModel.selection.hasRegion
        case .bringForward, .sendBackward, .bringToFront, .sendToBack,
             .ungroup, .toggleLock, .toggleHidden:
            return viewModel.selection.hasObjects
        case .group, .alignLeft, .alignHCenter, .alignRight,
             .alignTop, .alignVCenter, .alignBottom:
            return viewModel.selection.objectIDs.count >= 2
        case .distributeHorizontally, .distributeVertically:
            return viewModel.selection.objectIDs.count >= 3
        case .fontPanel, .textBold, .textItalic, .textUnderline,
             .textAlignLeft, .textAlignCenter, .textAlignRight, .textPlate:
            return viewModel.hasEditableText
        case .mergeDown: return viewModel.canMergeDown
        case .deleteLayer: return viewModel.layers.count > 1
        case .rasterizeLayer: return viewModel.activeLayer?.isVector ?? false
        case .flattenImage: return viewModel.layers.count > 1
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
