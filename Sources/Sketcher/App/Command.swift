import Foundation

/// Every user-invocable action, in one enum.
///
/// INVARIANT: menu bar, context menus, toolbar buttons, and keyboard all route
/// through this and `CommandDispatch`. At this tool count, that is the
/// difference between one maintainable app and four diverging copies of the
/// feature list — and it makes macOS's Help-menu search a free command palette.
enum Command: String, CaseIterable, Sendable {
    // Edit
    case undo, redo
    case cut, copy, paste, pasteInPlace, duplicate
    case delete, selectAll, deselect
    case exportImage

    // Arrange
    case bringForward, sendBackward, bringToFront, sendToBack
    case group, ungroup
    case alignLeft, alignHCenter, alignRight, alignTop, alignVCenter, alignBottom
    case distributeHorizontally, distributeVertically
    case toggleLock, toggleHidden

    // Tools
    case toolSelect, toolBrush, toolEraser, toolRectangle, toolEllipse
    case toolLine, toolArrow, toolPolygon, toolHand, toolZoom
    case toolEyedropper, toolRedact

    // Color
    case swapColors, resetColors, screenEyedropper

    // Canvas
    case backgroundLight, backgroundDark, backgroundTransparent
    case toggleCanvasMode

    // View
    case zoomIn, zoomOut, zoomActualSize, zoomToFit

    // Brush
    case brushSizeDown, brushSizeUp

    var title: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .pasteInPlace: return "Paste in Place"
        case .duplicate: return "Duplicate"
        case .delete: return "Delete"
        case .selectAll: return "Select All"
        case .deselect: return "Deselect"
        case .exportImage: return "Export\u{2026}"
        case .bringForward: return "Bring Forward"
        case .sendBackward: return "Send Backward"
        case .bringToFront: return "Bring to Front"
        case .sendToBack: return "Send to Back"
        case .group: return "Group"
        case .ungroup: return "Ungroup"
        case .alignLeft: return "Align Left"
        case .alignHCenter: return "Align Center"
        case .alignRight: return "Align Right"
        case .alignTop: return "Align Top"
        case .alignVCenter: return "Align Middle"
        case .alignBottom: return "Align Bottom"
        case .distributeHorizontally: return "Distribute Horizontally"
        case .distributeVertically: return "Distribute Vertically"
        case .toggleLock: return "Lock / Unlock"
        case .toggleHidden: return "Hide / Show"
        case .toolSelect: return "Select"
        case .toolBrush: return "Brush"
        case .toolEraser: return "Eraser"
        case .toolRectangle: return "Rectangle"
        case .toolEllipse: return "Ellipse"
        case .toolLine: return "Line"
        case .toolArrow: return "Arrow"
        case .toolPolygon: return "Polygon"
        case .toolHand: return "Hand"
        case .toolZoom: return "Zoom"
        case .toolEyedropper: return "Eyedropper"
        case .toolRedact: return "Redact"
        case .swapColors: return "Swap Colors"
        case .resetColors: return "Reset to Black & White"
        case .screenEyedropper: return "Screen Eyedropper\u{2026}"
        case .backgroundLight: return "Light Canvas"
        case .backgroundDark: return "Dark Canvas"
        case .backgroundTransparent: return "Transparent Canvas"
        case .toggleCanvasMode: return "Toggle Contained / Infinite"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomActualSize: return "Actual Size"
        case .zoomToFit: return "Zoom to Fit"
        case .brushSizeDown: return "Decrease Brush Size"
        case .brushSizeUp: return "Increase Brush Size"
        }
    }

    /// Menu key equivalent. Single-letter tool keys are deliberately absent:
    /// those are handled by `CanvasEventView`, because a menu key equivalent
    /// would fire while the user is typing into a text field.
    var keyEquivalent: (key: String, modifiers: CommandModifiers)? {
        switch self {
        case .undo: return ("z", [.command])
        case .redo: return ("z", [.command, .shift])
        case .cut: return ("x", [.command])
        case .copy: return ("c", [.command])
        case .paste: return ("v", [.command])
        case .pasteInPlace: return ("v", [.command, .shift])
        case .duplicate: return ("d", [.command])
        case .selectAll: return ("a", [.command])
        case .exportImage: return ("e", [.command, .shift])
        case .bringForward: return ("]", [.command])
        case .sendBackward: return ("[", [.command])
        case .bringToFront: return ("]", [.command, .option])
        case .sendToBack: return ("[", [.command, .option])
        case .group: return ("g", [.command])
        case .ungroup: return ("g", [.command, .shift])
        case .toggleLock: return ("l", [.command, .shift])
        case .zoomIn: return ("+", [.command])
        case .zoomOut: return ("-", [.command])
        case .zoomActualSize: return ("0", [.command])
        case .zoomToFit: return ("1", [.command])
        default: return nil
        }
    }
}

struct CommandModifiers: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let command = CommandModifiers(rawValue: 1 << 0)
    static let shift = CommandModifiers(rawValue: 1 << 1)
    static let option = CommandModifiers(rawValue: 1 << 2)
    static let control = CommandModifiers(rawValue: 1 << 3)
}
