import Foundation
import AppKit
import ApplicationServices
import JevCore

/// Ways to cut the number of targets down to the ones you mean.
///
/// Reducing the count is worth more than clever labels: "select 7" out of nine
/// images beats "select 47" out of eighty of everything, and digits transcribe
/// far better than letter pairs.
enum HintScope {
    /// What kind of thing to number.
    enum Kind: String, CaseIterable {
        case images, buttons, links, fields, text, menus, files, everything

        /// Spoken forms, so "show guides for pictures" works as well as images.
        static let spoken: [String: Kind] = [
            "images": .images, "image": .images, "pictures": .images, "photos": .images,
            "icons": .images, "files": .files, "folders": .files, "documents": .files,
            "buttons": .buttons, "button": .buttons,
            "links": .links, "link": .links,
            "fields": .fields, "text fields": .fields, "inputs": .fields, "boxes to type": .fields,
            "text": .text, "labels": .text,
            "menus": .menus, "menu": .menus, "menu bar": .menus,
            "everything": .everything, "all": .everything,
        ]

        var roles: [String] {
            switch self {
            case .images, .files: return ["AXImage"]
            case .buttons: return ["AXButton", "AXMenuButton", "AXPopUpButton",
                                   "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]
            case .links: return ["AXLink"]
            case .fields: return ["AXTextField", "AXTextArea", "AXComboBox"]
            case .text: return ["AXStaticText"]
            case .menus: return ["AXMenuBarItem", "AXMenuItem"]
            case .everything: return []
            }
        }
    }

    /// Which part of the window.
    enum Region: String, CaseIterable {
        case sidebar, navbar, main, menubar, toolbar

        static let spoken: [String: Region] = [
            "sidebar": .sidebar, "side bar": .sidebar, "left panel": .sidebar,
            "navbar": .navbar, "nav bar": .navbar, "navigation": .navbar,
            "address bar": .navbar, "top bar": .navbar,
            "main": .main, "main content": .main, "content": .main, "body": .main,
            "menubar": .menubar, "menu bar": .menubar, "menus": .menubar,
            "toolbar": .toolbar, "tool bar": .toolbar,
        ]
    }

    /// Does this control belong to the named region?
    ///
    /// Semantic information first where it exists; otherwise geometry against
    /// the window's own frame, which is crude but is all the accessibility
    /// tree offers — nothing marks a container as "the sidebar".
    static func matches(_ control: JevIntent.Control, region: Region, window: CGRect) -> Bool {
        guard window.width > 0, window.height > 0 else { return false }
        let relativeX = (control.x - window.minX) / window.width
        let relativeY = (control.y - window.minY) / window.height
        let relativeWidth = control.width / window.width

        // Order matters: the nav bar is tested before the sidebar, because a
        // back button sits in the top-left and belongs to the toolbar rather
        // than the sidebar beneath it.
        //
        // Thresholds measured against a real Finder window (900x1129):
        //   sidebar rows   rx 0.026-0.18, rw 0.12-0.17, from ry 0.05 downward
        //   toolbar        ry 0.007
        //   content        rx 0.238+, ry 0.067+
        // An earlier rule required ry > 0.14 for the sidebar to keep the
        // toolbar out, which excluded most of the sidebar itself.
        let isTopStrip = relativeY < 0.06
        let endsInLeftQuarter = (relativeX + relativeWidth) < 0.25

        switch region {
        case .menubar:
            return control.role == "AXMenuBarItem" || control.y < window.minY

        case .navbar, .toolbar:
            return isTopStrip && control.y >= window.minY

        case .sidebar:
            // Contained entirely within the left quarter, and not part of the
            // toolbar strip above it.
            return !isTopStrip && endsInLeftQuarter

        case .main:
            return !isTopStrip && !endsInLeftQuarter
        }
    }

    /// The frontmost window's frame, for the geometric tests above.
    static func frontmostWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue.map({ $0 as! AXUIElement }) else { return nil }

        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Regions that actually contain something right now — the closed list
    /// Jev chooses from, so it can only ever name a region that exists.
    static func availableRegions(in controls: [JevIntent.Control]) -> [Region] {
        guard let window = frontmostWindowFrame() else { return [.menubar] }
        return Region.allCases.filter { region in
            controls.contains { matches($0, region: region, window: window) }
        }
    }
}
