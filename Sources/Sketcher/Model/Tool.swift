import Foundation

/// The active tool. Shortcuts follow the cross-app conventions users already
/// have muscle memory for (Photoshop / Figma / Paint.NET agree on most of
/// these); see `KeyMap` for the full binding table.
enum Tool: String, CaseIterable, Sendable {
    case select        // V — objects
    case brush         // B
    case eraser        // E
    case rectangle     // R
    case ellipse       // O
    case line          // L
    case arrow         // A
    case polygon       // U
    case text          // T
    case redact        // J — blur / pixelate
    case eyedropper    // I
    case bucket        // G
    case marquee       // M — pixels
    case lasso         // Q
    case wand          // W
    case crop          // C
    case hand          // H
    case zoom          // Z

    /// Tools that create a new object by dragging out a rect.
    var isRectDrag: Bool {
        switch self {
        case .rectangle, .ellipse, .polygon, .redact, .crop, .marquee, .zoom: return true
        default: return false
        }
    }

    /// Tools that create a new object by dragging a start->end vector.
    var isVectorDrag: Bool {
        switch self {
        case .line, .arrow: return true
        default: return false
        }
    }

    /// Tools that accumulate freehand samples.
    var isFreehand: Bool {
        switch self {
        case .brush, .eraser, .lasso: return true
        default: return false
        }
    }

    /// Tools that create document content, as opposed to navigating or sampling.
    var createsContent: Bool {
        switch self {
        case .select, .hand, .zoom, .eyedropper, .marquee, .lasso, .wand, .crop:
            return false
        default:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .polygon: return "Polygon"
        case .text: return "Text"
        case .redact: return "Redact"
        case .eyedropper: return "Eyedropper"
        case .bucket: return "Fill"
        case .marquee: return "Rectangular Select"
        case .lasso: return "Lasso"
        case .wand: return "Magic Wand"
        case .crop: return "Crop"
        case .hand: return "Hand"
        case .zoom: return "Zoom"
        }
    }

    /// SF Symbol name for the toolbar.
    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .polygon: return "hexagon"
        case .text: return "textformat"
        case .redact: return "drop.halffull"
        case .eyedropper: return "eyedropper"
        case .bucket: return "paintbrush.fill"
        case .marquee: return "selection.pin.in.out"
        case .lasso: return "lasso"
        case .wand: return "wand.and.stars"
        case .crop: return "crop"
        case .hand: return "hand.raised"
        case .zoom: return "magnifyingglass"
        }
    }
}
