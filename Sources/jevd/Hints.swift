import Foundation
import AppKit
import JevCore

/// Numbered overlays for everything clickable on screen.
///
/// Describing a target out loud is the weak point of voice control: "the third
/// thumbnail", "the blue button". Numbering every actionable element turns that
/// into "select 4", which speech transcribes perfectly and needs no model.
///
/// The numbers come from the accessibility tree, so they only ever cover things
/// that genuinely exist and can genuinely be acted on.
final class Hints: @unchecked Sendable {
    static let shared = Hints()

    /// What the numbers cover.
    ///
    /// Focused window is the default because numbering something you cannot
    /// see is worse than useless — it invites picking a number over an
    /// occluded window. Targeting another app focuses it FIRST, so the numbers
    /// always describe what is actually in front of you. "Everywhere" exists
    /// for tiling setups where several windows really are visible at once.
    enum Scope: Sendable {
        case focusedWindow
        case app(bundleIdentifier: String)
        case everythingOnScreen
    }

    struct Hint: Codable, Sendable {
        let number: Int
        let label: String
        let role: String
        /// Normalised 0..1 against the display, so the phone can draw them over
        /// a scaled screenshot without knowing anything about resolution.
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        /// Screen coordinates, kept server-side for the actual click.
        let screenX: Double
        let screenY: Double
    }

    private let lock = NSLock()
    private var current: [Hint] = []
    /// Which app the current numbers were taken from. Numbers taken in one
    /// app mean nothing in another, and acting on them clicks whatever now
    /// occupies that slot.
    private var capturedFrom: pid_t = 0

    @discardableResult
    func refresh() -> [Hint] { refresh(scope: .focusedWindow) }

    /// Keep only the controls the user asked about, before numbering. Filtering
    /// after numbering would leave gaps — "select 7" when 7 is not shown.
    private func applyFilters(_ controls: [JevIntent.Control],
                              kind: HintScope.Kind?,
                              region: HintScope.Region?) -> [JevIntent.Control] {
        var kept = controls

        if let kind, kind != .everything {
            let roles = Set(kind.roles)
            kept = kept.filter { roles.contains($0.role) }
            // Finder shows files as AXImage with a filename; "files" means the
            // ones that are named, not decorative artwork.
            if kind == .files {
                kept = kept.filter { !$0.label.isEmpty }
            }
        }

        if let region, let window = HintScope.frontmostWindowFrame() {
            kept = kept.filter { HintScope.matches($0, region: region, window: window) }
        }
        return kept
    }

    /// Snapshot what is on screen and number it.
    func refresh(scope: Scope,
                 kind: HintScope.Kind? = nil,
                 region: HintScope.Region? = nil) -> [Hint] {
        let frame = Pointer.displayBounds()
        guard frame.width > 0, frame.height > 0 else { return [] }

        // Bring the target forward before looking at it. Enumerating a
        // background window produces numbers over something the user cannot
        // see, and pressing those elements usually needs it frontmost anyway.
        switch scope {
        case .app(let bundleIdentifier):
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier).first {
                app.unhide()
                app.activate(options: [.activateAllWindows])
                Thread.sleep(forTimeInterval: 0.35)
            }
        case .focusedWindow, .everythingOnScreen:
            break
        }

        // Ask for the roles we are going to keep. Filtering after a cap of 80
        // meant a request for links collected 80 mixed controls — nearly all
        // browser chrome — and then filtered them down to almost nothing.
        let wantedRoles: Set<String>? = (kind.map { $0 == .everything ? [] : Set($0.roles) })
            .flatMap { $0.isEmpty ? nil : $0 }
        var controls = JevIntent.frontmostControls(limit: 80, roles: wantedRoles)
            // Zero-sized elements cannot be drawn or aimed at.
            .filter { $0.width > 4 && $0.height > 4 }
            // Off-screen elements still report frames; numbering something you
            // cannot see is worse than useless.
            .filter { $0.x >= 0 && $0.y >= 0
                && $0.x < frame.width && $0.y < frame.height }

        // The menu bar hangs off the application, not the window, so it needs
        // its own pass. File, Edit, View and Go were simply never collected.
        controls += JevIntent.frontmostMenuBarItems()

        // With a tiling window manager several windows are genuinely visible,
        // so gather the other on-screen apps too when asked.
        if case .everythingOnScreen = scope {
            controls += JevIntent.controlsInOtherVisibleApps(limit: 60)
        }

        controls = applyFilters(controls, kind: kind, region: region)
        controls = JevIntent.inReadingOrder(controls)

        let hints = controls.enumerated().map { index, control in
            Hint(
                number: index + 1,
                label: control.label,
                role: control.role,
                x: control.x / frame.width,
                y: control.y / frame.height,
                width: control.width / frame.width,
                height: control.height / frame.height,
                screenX: control.x + control.width / 2,
                screenY: control.y + control.height / 2
            )
        }

        lock.lock()
        current = hints
        capturedFrom = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        lock.unlock()
        return hints
    }

    func hint(number: Int) -> Hint? {
        lock.lock(); defer { lock.unlock() }
        // Numbers belong to the app they were taken in.
        let nowFront = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        guard capturedFrom == 0 || capturedFrom == nowFront else { return nil }
        return current.first { $0.number == number }
    }

    var all: [Hint] {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func clear() {
        lock.lock(); current = []; lock.unlock()
    }

    /// Act on a numbered hint. Pressing the element is preferred; the stored
    /// coordinate is the fallback for things that do not respond to AXPress.
    func select(_ number: Int) -> ExecutionResult {
        guard let hint = hint(number: number) else {
            let count = all.count
            return .failed(reason: count == 0
                ? "No numbers are showing — say “show boxes” first"
                : "There is no number \(number); showing 1 to \(count)")
        }

        // Acting consumes the numbers: the screen has changed, so every other
        // number is now suspect. Leaving them up is how "select 19" later
        // pressed whatever had moved into slot 19.
        defer { clear() }

        let pressed = JevIntent.clickFrontmostControl(labelled: hint.label)
        if pressed.status == .ok {
            return .ok(reason: "Selected \(number): \(hint.label)")
        }
        let clicked = JevIntent.click(x: hint.screenX, y: hint.screenY)
        return clicked.status == .ok
            ? .ok(reason: "Selected \(number): \(hint.label)")
            : .failed(reason: "Could not act on \(number): \(hint.label)")
    }
}
