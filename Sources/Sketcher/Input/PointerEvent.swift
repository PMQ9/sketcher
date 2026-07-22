import AppKit
import CoreGraphics

/// A pointer sample in VIEW points, with everything read off a single
/// `NSEvent`.
///
/// Capturing location, modifiers, and pressure from the same event is what
/// eliminates the modifier race: querying `NSEvent.modifierFlags` separately
/// can observe a different instant than the location came from, which is how
/// "shift-constrain sometimes doesn't apply" bugs happen.
struct PointerEvent {
    var location: CGPoint          // view points, top-left origin (flipped view)
    var modifiers: EventModifiers
    var pressure: CGFloat          // 0...1
    var tilt: CGVector             // -1...1 per axis; .zero when unavailable
    var timestamp: TimeInterval
    var clickCount: Int

    @MainActor
    init(nsEvent event: NSEvent, in view: NSView) {
        self.location = view.convert(event.locationInWindow, from: nil)
        self.modifiers = EventModifiers(event.modifierFlags)
        self.timestamp = event.timestamp
        self.clickCount = Self.safeClickCount(event)

        // Tablet data lives on the event only for tablet-flavored events.
        // Checking `type` alone misses most drivers, which deliver a mouse
        // event whose SUBTYPE is .tabletPoint — that is the difference between
        // working pressure and pressure that reads 1.0 forever.
        let isTablet = event.type == .tabletPoint
            || (Self.hasSubtype(event) && event.subtype == .tabletPoint)

        if isTablet {
            self.pressure = CGFloat(event.pressure)
            self.tilt = CGVector(dx: event.tilt.x, dy: event.tilt.y)
        } else if event.type == .leftMouseDown || event.type == .leftMouseDragged {
            // Force Touch trackpads report through the same field; a plain mouse
            // reports 0 on drag, which must read as full pressure rather than
            // producing an invisible zero-width stroke.
            let p = CGFloat(event.pressure)
            self.pressure = p > 0 ? p : 1
            self.tilt = .zero
        } else {
            self.pressure = 1
            self.tilt = .zero
        }
    }

    /// `subtype` traps on event types that do not carry one.
    private static func hasSubtype(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .tabletPoint, .tabletProximity, .appKitDefined,
             .systemDefined, .applicationDefined, .periodic:
            return true
        default:
            return false
        }
    }

    /// `clickCount` is only valid on mouse events; reading it elsewhere traps.
    private static func safeClickCount(_ event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return event.clickCount
        default:
            return 1
        }
    }
}

extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: EventModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}
