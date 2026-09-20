import Foundation
import ApplicationServices
import JevCore

/// DialogSerialiser converts an AXUIElement dialog into compact, readable text.
/// It walks the element tree, extracting roles, titles, values, and pressable buttons.
/// Output is designed to be information-dense and stable for analysis by Jev.
public struct DialogSerialiser {
    private let maxDepth: Int = 8
    private let maxElementsPerLevel: Int = 50
    private let maxTotalElements: Int = 200

    // Role constants as strings (these cannot be imported directly)
    private static let kAXButtonRole = "AXButton"

    public init() {}

    /// Serialize an AXUIElement dialog to text.
    /// Returns a compact text representation with role, title, body, and buttons.
    /// - Parameter appName: the owning app's name, when it is known.
    ///   AppKit composes an alert icon's description as
    ///   "<app name> alert", so the name is what tells that apart from
    ///   something a person wrote.
    public func serialize(element: AXUIElement, appName: String = "") -> String {
        var elementCount: Int = 0
        var output = ""

        // Start with the window/dialog itself
        if let role = getAttribute(element, kAXRoleAttribute as CFString) as? String {
            output += "[\(role)]"
        }

        if let title = getAttribute(element, kAXTitleAttribute as CFString) as? String {
            output += " \(title)"
        }

        output += "\n"

        // The window's own description, when it is not furniture.
        //
        // It is either the name of the widget ("TestApp alert") or the
        // entire question — Electron, Qt, Flutter and Java put the
        // message here, via `accessibilityLabel`, and nowhere else.
        // Both were measured on this Mac. So it is judged, not
        // positioned: real content goes FIRST, where it becomes the
        // card's heading; furniture is held back as a last resort.
        //
        // Held back as a FALLBACK only, this lost the message on the
        // shape where the toolkit also draws a chrome label as static
        // text: the label counted as "something spoke", the fallback
        // never ran, and a card reading "Security Alert" carried a live
        // Delete button for "Delete all 412 messages in this mailbox?".
        let rootDescription = (getAttribute(element, kAXDescriptionAttribute as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rootIsFurniture = rootDescription.isEmpty
            || Self.furnitureDescriptions.contains(rootDescription.lowercased())
            || Self.isWidgetNoise(rootDescription)
        if !rootIsFurniture { output += rootDescription + "\n" }

        // Walk the tree and collect text and buttons
        let content = walkElement(element, depth: 0, elementCount: &elementCount,
                                  appName: appName, isRoot: true)
        output += content

        // Nothing said anything? Then even the furniture is better than
        // an empty card asking you to approve something.
        //
        // This test and the filtering in `walkElement` have to agree,
        // which is why ALL the filtering happens in this file rather
        // than half here and half in `DialogWatcher.heading`. When the
        // two disagreed, a furniture line the walk had kept made this
        // say "something spoke", suppressed the fallback, and was then
        // deleted by the heading — so the card arrived with no body at
        // all under a live Delete button. Measured on three shapes.
        //
        // `whereSeparator: \.isNewline`, not `split(separator: "\n")`:
        // Swift treats "\r\n" as one grapheme, the same trap `heading`
        // carries a paragraph about avoiding.
        let saidSomething = content
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .contains { !$0.hasPrefix("BUTTON: ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !saidSomething, rootIsFurniture, !rootDescription.isEmpty,
           !Self.furnitureDescriptions.contains(rootDescription.lowercased()) {
            // …but not a bare "alert". Heading a card with that says
            // nothing the badge does not already say, and `heading`
            // falls through to the app's name, which at least names who
            // is asking.
            output += rootDescription + "\n"
        }

        return output
    }

    /// Descriptions that name the widget rather than say anything.
    ///
    /// Matched by value on a CHILD element — the alert icon describes
    /// itself as "application icon", and as prose that was the first
    /// line of every alert body.
    private static let furnitureDescriptions: Set<String> = [
        "alert", "application icon", "dialog", "sheet", "window",
        "image", "icon", "group", "toolbar", "splitter", "unknown",
    ]

    /// Does this string name a widget rather than say something?
    ///
    /// Two words at most and no sentence punctuation, ending in a word
    /// for a piece of UI: "warning icon", "print dialog",
    /// "liveholder.bin alert". A real message is longer, or ends like a
    /// sentence, or both — "Close this window" is three words and
    /// survives.
    ///
    /// Applied ONLY to a description, never to a value. That is the line
    /// that makes this safe: an element's description labels the widget,
    /// an `AXStaticText`'s value IS the message. Applied to values too,
    /// this rule ate a stock `NSAlert` whose entire message was
    /// "Security Alert" and left the card blank — measured.
    public static func isWidgetNoise(_ line: String, appName: String = "") -> Bool {
        var lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // "Google Chrome alert" is the app's name with a widget word
        // stuck on the end. Take the name off and the rest is judged on
        // its own, so the rule does not have to care how many words are
        // in someone's product name.
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !name.isEmpty, lowered.hasPrefix(name + " ") {
            lowered = String(lowered.dropFirst(name.count + 1))
        }
        guard let last = lowered.last, !".?!:".contains(last) else { return false }
        let words = lowered.split(separator: " ")
        guard words.count <= 2, let final = words.last else { return false }
        let widgets: Set<String> = ["alert", "dialog", "sheet", "window",
                                    "panel", "notification", "prompt", "icon"]
        return widgets.contains(String(final))
    }

    /// The window's own description: furniture, or the whole message.
    ///
    /// There is no way to tell which by looking at it. Two measurements
    /// on this Mac, both real:
    ///
    ///   * a stock `NSAlert` window describes itself as
    ///     "liveholder.bin alert" — the widget's name, emitted as prose
    ///     it became the first line of the body and therefore the
    ///     card's heading, so the phone pushed "TestApp — TestApp
    ///     alert";
    ///   * a window built the way Electron, Qt, Flutter and Java expose
    ///     things — via `accessibilityLabel` — describes itself as
    ///     "Delete all 412 messages in this mailbox? This cannot be
    ///     undone.", which is the entire question being asked.
    ///
    /// So it is used as a FALLBACK: emitted only when walking the
    /// children produced no prose at all. An alert's message lives in
    /// its static text, and a card with an empty body under a live
    /// Delete button is the worse of the two failures by a distance.
    ///
    /// Two earlier attempts got this wrong in each direction — first
    /// emitting it always (every card headed "alert"), then suppressing
    /// it by ROLE (the Electron message lost entirely, measured).
    ///
    /// Recursively walk an element tree, extracting text and button information.
    private func walkElement(_ element: AXUIElement, depth: Int, elementCount: inout Int,
                             appName: String = "", isRoot: Bool = false) -> String {
        guard depth < maxDepth else { return "" }
        guard elementCount < maxTotalElements else { return "" }

        var output = ""
        elementCount += 1

        let role = getAttribute(element, kAXRoleAttribute as CFString) as? String ?? "unknown"

        // Extract meaningful text from this element.
        //
        // A BUTTON's own value and description are marked as such, not
        // emitted as bare prose. An icon button carries its label in
        // AXDescription rather than AXTitle, and as a bare line it became
        // the card's HEADING on any sheet with no AXTitle of its own —
        // so a card read "Close" above the message it was meant to
        // introduce. Marking it at the source means the one filter that
        // already exists handles it, rather than the heading parser
        // growing another special case. This heading has been wrong three
        // times; fixing the producer is cheaper than fixing the parser
        // again.
        let mark = role == Self.kAXButtonRole ? "BUTTON: " : ""
        if let value = getAttribute(element, kAXValueAttribute as CFString) as? String, !value.isEmpty {
            output += mark + value + "\n"
        }

        // The root's own description is decided after the walk, by
        // whether anything else spoke. See `serialize`.
        //
        // A child's description is a label for the widget, so it is
        // filtered here — and only here, so that `saidSomething` above
        // counts exactly the lines that will survive to the card.
        //
        // An image in a dialog is the alert icon. Its description is
        // AppKit's own composition — "<app name> alert" — and the
        // two-word rule could not see it: "liveholder.bin alert" is two
        // words and was caught, "Google Chrome alert" is three and
        // became the card's heading and the push body, which is the
        // "App — App alert" notification all over again. Every app with
        // a space in its name: Google Chrome, Microsoft Word, Visual
        // Studio Code, System Settings.
        if !isRoot, role != "AXImage",
           let description = getAttribute(element, kAXDescriptionAttribute as CFString) as? String,
           !description.isEmpty,
           !Self.furnitureDescriptions.contains(
               description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           !Self.isWidgetNoise(description, appName: appName) {
            output += mark + description + "\n"
        }

        // Special handling for buttons
        if role == Self.kAXButtonRole {
            // A stock `NSAlert` has a button with an empty title, which
            // emitted a bare "BUTTON: ". The reader trims lines before
            // filtering them out, so it arrived as a literal "BUTTON:"
            // line in the body of the card.
            if let title = getAttribute(element, kAXTitleAttribute as CFString) as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output += "BUTTON: \(title)\n"
            }
        }

        // Walk children
        if let children = getAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            let childLimit = min(children.count, maxElementsPerLevel)
            for child in children.prefix(childLimit) {
                guard elementCount < maxTotalElements else { break }
                output += walkElement(child, depth: depth + 1, elementCount: &elementCount,
                                      appName: appName)
            }
        }

        return output
    }

    /// Safely get an attribute from an AXUIElement.
    private func getAttribute(_ element: AXUIElement, _ attribute: CFString) -> Any? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        return result == .success ? value : nil
    }

    /// Extract all pressable buttons from a dialog element.
    /// Returns a list of button labels that can be pressed.
    public func extractButtons(element: AXUIElement) -> [String] {
        var elementCount: Int = 0
        var buttons: [String] = []
        findButtons(element, depth: 0, elementCount: &elementCount, into: &buttons)
        return buttons
    }

    /// Recursively find all buttons in an element tree.
    private func findButtons(_ element: AXUIElement, depth: Int, elementCount: inout Int, into buttons: inout [String]) {
        guard depth < maxDepth else { return }
        guard elementCount < maxTotalElements else { return }

        elementCount += 1

        let role = getAttribute(element, kAXRoleAttribute as CFString) as? String

        // Collect buttons — named ones, once each.
        //
        // An empty title made a card with one blank button that nothing
        // could ever press: `findButton(withTitle: "")` finds nothing,
        // the dialog is alive so the sweep will not withdraw the card,
        // and tapping it did nothing, forever. A duplicate title drew two
        // identical buttons that both pressed the first match.
        if role == Self.kAXButtonRole {
            if let title = getAttribute(element, kAXTitleAttribute as CFString) as? String,
               !Self.normalisedTitle(title).isEmpty,
               !buttons.contains(where: { Self.normalisedTitle($0) == Self.normalisedTitle(title) }) {
                buttons.append(title)
            }
        }

        // Walk children
        if let children = getAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            let childLimit = min(children.count, maxElementsPerLevel)
            for child in children.prefix(childLimit) {
                guard elementCount < maxTotalElements else { break }
                findButtons(child, depth: depth + 1, elementCount: &elementCount, into: &buttons)
            }
        }
    }

    /// Which of two button labels the person meant.
    ///
    /// **Exact, then unambiguous, then refuse.** The old rule was a
    /// BIDIRECTIONAL substring test — `a.contains(b) || b.contains(a)` —
    /// and on the most common sheet on macOS it pressed the wrong button
    /// whichever way round the tree happened to be:
    ///
    ///   * "Save" first in the tree: tapping **Don't Save** pressed Save,
    ///     because "don't save" contains "save". Your document is written
    ///     when you said not to write it.
    ///   * "Don't Save" first: tapping **Save** pressed Don't Save.
    ///
    /// Either way jev reported `Pressed button 'Don't Save'`, so the phone
    /// and the journal both said the opposite of what happened. Same shape
    /// for Allow / Allow Once, Delete / Delete All, Open / Open Anyway —
    /// and in each pair the loose match favours the wider, more damaging
    /// option.
    ///
    /// `CuaBackend.bestMatch` has said this in a comment since it was
    /// written — "'Don't Save' and 'Save' differ by one word and the wrong
    /// choice loses your document" — and this file, the only one in the
    /// area untouched since the first commit, never got the treatment.
    public static func normalisedTitle(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            // A menu title spelled with three dots and one spelled with
            // an ellipsis are the same title. macOS uses the character;
            // anyone typing the label uses the dots.
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pick the button, from every candidate in the dialog, or nobody.
    ///
    /// Collecting them all first is the point: a decision between "Save"
    /// and "Don't Save" cannot be made by looking at one of them.
    public static func chooseButton(wanted: String, from titles: [String]) -> String? {
        let want = normalisedTitle(wanted)
        guard !want.isEmpty else { return nil }
        let named = titles.filter { !normalisedTitle($0).isEmpty }

        if let exact = named.first(where: { normalisedTitle($0) == want }) { return exact }

        // Only when it cannot be anything else — and never across a
        // negation. "Don't Save" is the ONLY candidate containing "Save"
        // on a two-button sheet, so "unambiguous" happily returned the
        // opposite of what was asked. Narrowing is fine ("Replace" ->
        // "Replace Existing"); inverting is not.
        // A candidate may only ADD TO THE END. The containment tier is
        // gone: it is what let "Don't Save" stand in for "Save", and
        // every narrowing worth having is a prefix anyway. Then the
        // negation test, for languages that invert with a suffix.
        let prefixed = named.filter {
            normalisedTitle($0).hasPrefix(want) && !Negation.differs(wanted, $0)
        }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// Find a button element by title within a dialog.
    ///
    /// Resolves the label against every button in the dialog first, then
    /// walks for that exact title — so tree order can no longer decide
    /// which of two similar buttons gets pressed.
    public func findButton(in element: AXUIElement, withTitle title: String) -> (element: AXUIElement, title: String)? {
        guard let chosen = Self.chooseButton(wanted: title, from: extractButtons(element: element))
        else { return nil }
        var elementCount: Int = 0
        guard let found = findButtonRecursive(element, title: chosen, depth: 0, elementCount: &elementCount)
        else { return nil }
        // The RESOLVED title travels with the element. Reporting the
        // requested one is how round nine's wrong-press stayed invisible
        // for nine rounds: the phone, the journal and the audit log all
        // said "Pressed 'Save'" while something else was pressed.
        return (found, chosen)
    }

    private func findButtonRecursive(_ element: AXUIElement, title: String, depth: Int, elementCount: inout Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard elementCount < maxTotalElements else { return nil }

        elementCount += 1

        let role = getAttribute(element, kAXRoleAttribute as CFString) as? String

        // Exact now. `title` has already been resolved to one real button
        // by `chooseButton`; matching loosely here would undo that.
        if role == Self.kAXButtonRole {
            if let buttonTitle = getAttribute(element, kAXTitleAttribute as CFString) as? String,
               Self.normalisedTitle(buttonTitle) == Self.normalisedTitle(title) {
                return element
            }
        }

        // Search children
        if let children = getAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            let childLimit = min(children.count, maxElementsPerLevel)
            for child in children.prefix(childLimit) {
                guard elementCount < maxTotalElements else { break }
                if let found = findButtonRecursive(child, title: title, depth: depth + 1, elementCount: &elementCount) {
                    return found
                }
            }
        }

        return nil
    }
}
