import Foundation
import AppKit
import JevCore

/// The pointer, driven from the phone.
///
/// A remote screen you can only single-tap is not really usable, so this covers
/// the gestures a trackpad has: click, double click, right click, move, drag
/// and momentum-free scrolling.
///
/// None of this reaches a TCC consent sheet. These are synthetic events and
/// macOS discards them there regardless of how they were produced.
enum Pointer {
    /// Where the pointer is right now, in the same top-left-origin screen
    /// coordinates the synthetic events use.
    ///
    /// `NSEvent.mouseLocation` is bottom-left origin and would put the marker
    /// on the wrong half of the screen; a null-source CGEvent reports the same
    /// frame everything else here works in.
    /// The display everything is measured against.
    ///
    /// Not `NSScreen.main`: that is whichever screen has keyboard focus, and
    /// its frame is in AppKit's bottom-left coordinates, while CGEvent, the
    /// window server and ScreenCaptureKit all work top-left. On a single
    /// display at the origin those happen to agree numerically, which is why
    /// the mismatch has never shown up — it would appear the moment a second
    /// display was plugged in, as taps landing in the wrong place.
    static func displayBounds() -> CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    static func location() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func perform(_ kind: String, at point: CGPoint) -> ExecutionResult {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed(reason: "Could not create an event source")
        }

        switch kind {
        case "click":
            return click(source, point, button: .left, clicks: 1)
        case "double":
            return click(source, point, button: .left, clicks: 2)
        case "right":
            return click(source, point, button: .right, clicks: 1)
        case "move":
            post(source, .mouseMoved, point, .left)
            return .ok(reason: "Moved")
        case "dragStart":
            post(source, .leftMouseDown, point, .left)
            return .ok(reason: "Dragging")
        case "dragMove":
            post(source, .leftMouseDragged, point, .left)
            return .ok(reason: "Dragging")
        case "dragEnd":
            post(source, .leftMouseUp, point, .left)
            return .ok(reason: "Dropped")
        default:
            return .failed(reason: "Unknown pointer action “\(kind)”")
        }
    }

    /// Scroll at a point, in pixel units so a swipe feels one-to-one.
    static func scroll(dx: Double, dy: Double, at point: CGPoint) -> ExecutionResult {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed(reason: "Could not create an event source")
        }
        post(source, .mouseMoved, point, .left)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        ) else {
            return .failed(reason: "Could not synthesise a scroll")
        }
        event.post(tap: .cghidEventTap)
        return .ok(reason: "Scrolled")
    }

    private static func click(_ source: CGEventSource, _ point: CGPoint,
                              button: CGMouseButton, clicks: Int) -> ExecutionResult {
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        for click in 1...clicks {
            guard let downEvent = CGEvent(mouseEventSource: source, mouseType: down,
                                          mouseCursorPosition: point, mouseButton: button),
                  let upEvent = CGEvent(mouseEventSource: source, mouseType: up,
                                        mouseCursorPosition: point, mouseButton: button) else {
                return .failed(reason: "Could not synthesise the click")
            }
            // A double click is not two clicks: the click count must be set on
            // the events or the app treats them as separate taps.
            downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            downEvent.post(tap: .cghidEventTap)
            upEvent.post(tap: .cghidEventTap)
        }
        let label = clicks > 1 ? "Double clicked" : (button == .right ? "Right clicked" : "Clicked")
        return .ok(reason: "\(label) at \(Int(point.x)), \(Int(point.y))")
    }

    private static func post(_ source: CGEventSource, _ type: CGEventType,
                             _ point: CGPoint, _ button: CGMouseButton) {
        CGEvent(mouseEventSource: source, mouseType: type,
                mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }
}
