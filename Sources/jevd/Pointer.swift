import Foundation
import AppKit
import JevCore

/// The pointer, driven from the phone.
///
/// A remote screen you can only single-tap is not really usable, so this covers
/// the gestures a trackpad has: click, double click, right click, move, drag
/// and momentum-free scrolling.
///
/// Synthetic events do not reach a TCC consent sheet — macOS discards them
/// there regardless of how they were produced. That refusal stands whenever
/// jev is on its own. When the USB HID bridge is plugged in, the same
/// POINTER gestures go out over real hardware instead, so a sheet you can
/// click through becomes reachable; see HIDBridge. Keystrokes do not: they
/// are still CGEvent, so a sheet that wants Tab and Return is still out of
/// reach with the board attached.
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

    /// A 0…1 pair off the wire, turned into a point on the display.
    ///
    /// The one place a phone coordinate becomes a Mac coordinate, so the
    /// check cannot be forgotten on a route. `Int(point.x)` appears in every
    /// success message below, and `Int(_:)` on a Double past `Int.max` is a
    /// TRAP, not a throw — the process aborts. So `POST /api/tap
    /// {"x":1e16,"y":0.5}` from any authenticated client killed the daemon.
    /// The same reasoning `scroll` already spells out, applied to the route
    /// it was not applied to.
    ///
    /// Clamped rather than merely rejected: a tap a little outside the
    /// picture is a rounding error on a phone, not a reason to refuse.
    static func screenPoint(nx: Double, ny: Double, in bounds: CGRect) -> CGPoint? {
        guard nx.isFinite, ny.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite else { return nil }
        return CGPoint(x: min(1, max(0, nx)) * bounds.width,
                       y: min(1, max(0, ny)) * bounds.height)
    }

    static func perform(_ kind: String, at point: CGPoint) -> ExecutionResult {
        // Belt and braces: every caller should be coming through
        // `screenPoint`, and this is what happens if one ever does not.
        // Finite is not enough — 1e30 is finite and still past `Int.max`,
        // which is where the trap is. A billion points is a hundred times
        // any display anyone owns.
        let far = 1e9
        guard point.x.isFinite, point.y.isFinite,
              abs(point.x) < far, abs(point.y) < far else {
            return .failed(reason: "That is not a place on the screen")
        }
        // Real hardware first, when it is attached. Everything below is the
        // synthetic path, which stays the default and the fallback.
        if let viaHardware = performOverBridge(kind, at: point) { return viaHardware }

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

    /// The same gesture as a physical mouse would make, if a board is plugged
    /// in. Nil means there is no board, or it stopped answering mid-command —
    /// either way the caller carries on with CGEvent, so unplugging the cable
    /// degrades to the old behaviour instead of dropping the action.
    private static func performOverBridge(_ kind: String, at point: CGPoint) -> ExecutionResult? {
        guard HIDBridge.isAttached() else { return nil }
        let bounds = displayBounds()

        switch kind {
        case "click":
            guard HIDBridge.click(at: point, in: bounds) else { return nil }
            return .ok(reason: "Clicked at \(Int(point.x)), \(Int(point.y))")
        case "double":
            guard HIDBridge.click(at: point, in: bounds, count: 2) else { return nil }
            return .ok(reason: "Double clicked at \(Int(point.x)), \(Int(point.y))")
        case "right":
            guard HIDBridge.click(at: point, in: bounds, button: .right) else { return nil }
            return .ok(reason: "Right clicked at \(Int(point.x)), \(Int(point.y))")
        case "move":
            guard HIDBridge.move(to: point, in: bounds) else { return nil }
            return .ok(reason: "Moved")
        default:
            // Drags are a sequence the board runs in one command, so the
            // three-part CGEvent dance has no hardware equivalent. Let those
            // fall through rather than half-implementing them here.
            return nil
        }
    }

    /// Scroll at a point, in pixel units so a swipe feels one-to-one.
    static func scroll(dx: Double, dy: Double, at point: CGPoint) -> ExecutionResult {
        // A bad number here is not a bad scroll, it is a dead daemon.
        //
        // `Int(x)` and `Int32(x)` TRAP on infinity or on anything past the
        // type's range — not an error you can catch, an abort. Both appear
        // below, so `POST /api/swipe {"dy":1e300}` from any authenticated
        // client took jevd down. The shipped phone cannot produce one, which
        // is exactly why this needed saying out loud rather than assuming.
        guard dx.isFinite, dy.isFinite, point.x.isFinite, point.y.isFinite else {
            return .failed(reason: "That is not a distance I can scroll")
        }
        // Far past the tallest display anyone has; a gesture cannot mean more.
        let limit = 30_000.0
        let dx = min(limit, max(-limit, dx))
        let dy = min(limit, max(-limit, dy))

        // The board's wheel is vertical only, so a sideways swipe has no
        // hardware equivalent — and rounding a small dy to zero would send a
        // scroll of nothing. Both used to report success. Fall through to
        // CGEvent, which handles either axis.
        let notches = Int((dy / 8).rounded())
        if HIDBridge.isAttached(), abs(dx) < abs(dy), notches != 0,
           HIDBridge.scroll(at: point, in: displayBounds(), amount: notches) {
            return .ok(reason: "Scrolled")
        }
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
