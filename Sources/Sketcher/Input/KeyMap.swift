import AppKit
import Foundation

/// Single-key tool shortcuts.
///
/// Bindings follow the conventions users already have muscle memory for —
/// Photoshop, Figma, and Paint.NET agree on most of these. Command-modified
/// keys are NOT handled here: those belong to the menu bar, which owns key
/// equivalents and gets validation and discoverability for free.
enum KeyMap {
    static let toolKeys: [Character: Tool] = [
        "v": .select,
        "b": .brush,
        "e": .eraser,
        "r": .rectangle,
        "o": .ellipse,
        "l": .line,
        "a": .arrow,
        "u": .polygon,
        "t": .text,
        "j": .redact,
        "i": .eyedropper,
        "g": .bucket,
        "m": .marquee,
        "q": .lasso,
        "w": .wand,
        "c": .crop,
        "h": .hand,
        "z": .zoom
    ]

    static func tool(for character: Character) -> Tool? {
        toolKeys[Character(character.lowercased())]
    }

    /// Backspace arrives as U+007F (DEL), which does NOT compare equal to
    /// SwiftUI's `KeyEquivalent.delete` — a `case .delete` switch silently
    /// misses it. Match the raw scalars instead.
    static func isDeleteKey(_ character: Character) -> Bool {
        character == "\u{7F}" || character == "\u{8}" || character == "\u{F728}"
    }

    static func isEscape(_ character: Character) -> Bool {
        character == "\u{1B}"
    }

    static func isReturn(_ character: Character) -> Bool {
        character == "\r" || character == "\n" || character == "\u{3}"
    }

    /// Arrow-key nudge direction in canvas pixels, or nil.
    static func nudge(for keyCode: UInt16, shift: Bool) -> CGPoint? {
        let step: CGFloat = shift ? 10 : 1
        switch keyCode {
        case 123: return CGPoint(x: -step, y: 0)   // left
        case 124: return CGPoint(x: step, y: 0)    // right
        case 125: return CGPoint(x: 0, y: step)    // down  (y-down space)
        case 126: return CGPoint(x: 0, y: -step)   // up
        default: return nil
        }
    }

    static let spaceKeyCode: UInt16 = 49
    static let escapeKeyCode: UInt16 = 53

    static func isBracket(_ character: Character) -> Int? {
        switch character {
        case "[": return -1
        case "]": return 1
        default: return nil
        }
    }
}
