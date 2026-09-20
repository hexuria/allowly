import Foundation
import CoreGraphics
import JevCore

/// jev's looking and pointing, expressed in Cua Driver tools.
///
/// This replaces the hand-rolled accessibility walk. That walk was 800 lines
/// of "descend the tree, guess which node the human meant, click it", and its
/// failure mode was the worst kind: it would confidently click the *wrong*
/// control rather than admit it could not find the right one. The driver
/// refuses instead, and tells you why — off-Space, unresolved window, stale
/// snapshot. Refusing is the behaviour we want in something holding the mouse.
///
/// One rule carried over from the old code and kept deliberately: we never
/// invent a target. Every action names a control the driver just told us
/// exists, by its snapshot token. If the label does not match, that is a
/// failure, not an invitation to pick the nearest thing.
public struct CuaBackend: Sendable {

    public struct Element: Sendable {
        public let index: Int
        public let role: String
        public let label: String
        public let value: String?
        public let token: String?
        public let enabled: Bool
        /// Screen position in POINTS, as the driver reports it.
        public let frame: CGRect?
        /// True for anything drawn by a web view.
        public let inWebContent: Bool

        public init(index: Int, role: String, label: String,
                    value: String?, token: String?, enabled: Bool,
                    frame: CGRect? = nil, inWebContent: Bool = false) {
            self.index = index; self.role = role; self.label = label
            self.value = value; self.token = token; self.enabled = enabled
            self.frame = frame; self.inWebContent = inWebContent
        }
    }

    public struct Target: Sendable {
        public let pid: Int
        public let windowID: Int
        public let appName: String
        /// The window's size, so a wheel event can be aimed inside it.
        public let width: Double
        public let height: Double
    }

    private let driver: CuaDriver

    public init(driver: CuaDriver = .shared) {
        self.driver = driver
    }

    public func isAvailable() async -> Bool {
        guard await driver.binary() != nil else { return false }
        return await driver.ensureRunning()
    }

    /// The three distinct ways a command can come back with nothing, said in
    /// words a person in another room can act on.
    ///
    /// They were all "Nothing pressable on screen" before, which is a lie in
    /// two cases out of three and gave no hint what to do about it. A driver
    /// that has lost its session, a window on the other monitor, and a screen
    /// that genuinely has no buttons on it need three different responses
    /// from the human.
    public enum Refusal: Error, CustomStringConvertible, Sendable {
        /// The driver could not be reached or would not answer.
        case cannotSee(String)
        /// Something is in front, but not on the display the phone shows.
        case notOnThisScreen(String)
        /// The screen was read fine and has nothing of that kind on it.
        case nothingThere(String)

        public var description: String {
            switch self {
            case .cannotSee(let why):
                return "Cannot see the screen right now — \(why)"
            case .notOnThisScreen(let app):
                return "\(app) is on your other display, which this phone is not showing"
            case .nothingThere(let what):
                return what
            }
        }
    }

    // MARK: - Finding what is in front

    /// The frontmost app's frontmost titled window.
    ///
    /// Untitled windows are skipped: they are overwhelmingly sheets' shadow
    /// surfaces, tooltips and off-screen scratch windows, and picking one puts
    /// every later call on a window the human cannot see.
    public func frontmostTarget() async throws -> Target {
        // `display()` throws rather than handing back an unusable Shown, so
        // there is nothing left to check here.
        let shown = try await display()
        let apps = try await driver.call("list_apps")
        guard let list = apps["apps"] as? [[String: Any]] else {
            throw CuaDriver.Failure("Cua Driver did not list any apps")
        }
        guard let active = list.first(where: { $0["active"] as? Bool == true }),
              let pid = active["pid"] as? Int else {
            throw CuaDriver.Failure("Nothing is frontmost")
        }
        let name = active["name"] as? String ?? "the frontmost app"

        let windows = try await driver.call("list_windows")
        let all = (windows["windows"] as? [[String: Any]]) ?? []

        // Order matters and list order is not it. An app like Chrome reports a
        // dozen windows, nearly all of them off-screen scratch surfaces with
        // no title; taking the first one would aim every later call at a
        // window nobody can see. Keep only what is titled, actually on screen
        // and on the Space you are looking at, then take the frontmost — which
        // is the LOWEST z_index, the way CGWindow orders them.
        let usable = all.filter {
            $0["pid"] as? Int == pid
                && ($0["title"] as? String)?.isEmpty == false
                && ($0["is_on_screen"] as? Bool) != false
                && ($0["on_current_space"] as? Bool) != false
        }
        // A window we could not measure is not a window on another monitor.
        // Reporting it as one sent people looking at the wrong screen.
        let unreadable = usable.contains { Self.rect($0["bounds"]) == nil }
        guard let window = Self.chooseWindow(usable, on: shown) else {
            if unreadable {
                throw Refusal.cannotSee("\(name)'s window would not report its position")
            }
            // Refuse, do not reach for a window on the other monitor. An
            // earlier version fell back to it, which computed the right
            // answer and then threw it away — so jev went on clicking in a
            // window nobody could see, which is the bug this was meant to fix.
            throw usable.isEmpty
                ? Refusal.nothingThere("\(name) has no window open")
                : Refusal.notOnThisScreen(name)
        }
        guard let windowID = window["window_id"] as? Int else {
            throw Refusal.cannotSee("\(name)'s window has no id")
        }
        let bounds = window["bounds"] as? [String: Any]
        return Target(
            pid: pid, windowID: windowID, appName: name,
            // list_windows says width/height; an element's frame says w/h.
            // Same driver, two spellings — accept both rather than silently
            // reading zero and falling back to the ambiguous keystroke path.
            width: Self.number(bounds?["width"] ?? bounds?["w"]) ?? 0,
            height: Self.number(bounds?["height"] ?? bounds?["h"]) ?? 0)
    }

    /// Which window a command should act in.
    ///
    /// Pure, and separated out so the policy can be asserted offline. The
    /// rule that matters is that there is **no fallback**: a window whose
    /// centre is not on the display the phone is showing is not a candidate,
    /// however far forward it sits.
    public static func chooseWindow(_ windows: [[String: Any]],
                                    on shown: Geometry.Shown) -> [String: Any]? {
        windows
            .filter { window in
                guard let bounds = rect(window["bounds"]) else { return false }
                return Geometry.isCentredOnShownDisplay(bounds, shown)
            }
            // Lowest z_index is frontmost, the way CGWindow orders them.
            .min { (($0["z_index"] as? Int) ?? .max) < (($1["z_index"] as? Int) ?? .max) }
    }

    /// Everything addressable in a window, with the snapshot tokens that make
    /// a later click refer to exactly these elements and no others.
    public func elements(of target: Target, limit: Int = 120) async throws -> [Element] {
        let state = try await driver.call("get_window_state", [
            "pid": target.pid,
            "window_id": target.windowID,
            "include_screenshot": false,
            "max_elements": limit,
        ], timeout: 45)

        if state["degraded"] as? Bool == true {
            let why = (state["degraded_reason"] as? String) ?? "the window could not be read"
            throw CuaDriver.Failure(Self.humanise(why))
        }
        let raw = (state["elements"] as? [[String: Any]]) ?? []
        return raw.compactMap { item in
            let label = (item["label"] as? String)
                ?? (item["title"] as? String)
                ?? (item["description"] as? String)
            guard let index = item["element_index"] as? Int,
                  let role = item["role"] as? String else { return nil }
            // An unlabelled control is still a control. Matching by name
            // ignores it anyway (an empty label matches nothing), but
            // numbering needs it — Chrome hands back buttons with no name
            // at all, and those are exactly the ones you cannot ask for.
            let named = label ?? ""
            return Element(
                index: index,
                role: role,
                // Chrome puts a second line of chatter in some labels; the
                // first line is the name a person would say.
                label: named.split(separator: "\n").first.map(String.init) ?? named,
                value: item["value"] as? String,
                token: item["element_token"] as? String,
                enabled: (item["enabled"] as? Bool) ?? true,
                frame: Self.rect(item["frame"]),
                inWebContent: (item["in_web_content"] as? Bool) ?? false
            )
        }
    }

    // MARK: - The display

    /// Point size of the screen, and the factor that turns points into the
    /// pixel coordinates a click actually wants.
    ///
    /// These are not the same number and that cost real debugging: clicks are
    /// addressed in SCREENSHOT pixels, while `get_screen_size` and every
    /// element frame are in POINTS. On a Retina Mac that is a factor of two,
    /// so a tap meant for the middle of the screen landed a quarter of the way
    /// in — every phone tap quietly hitting the top-left quadrant. Verified by
    /// clicking the same button at 1x (nothing) and 2x (it fired).
    /// The display the phone is being shown.
    ///
    /// Never returns an unusable one — it throws instead, so every caller
    /// can use what comes back without re-checking.
    public func display() async throws -> Geometry.Shown {
        let size = try await driver.call("get_screen_size")
        guard let width = Self.number(size["width"]), let height = Self.number(size["height"]) else {
            throw CuaDriver.Failure("Cua Driver would not report the screen size")
        }
        // No default. The whole pixel conversion hangs on this number, and
        // defaulting it to 1 is precisely the factor-of-two bug that put
        // every tap in the top-left quadrant — silently, with no error to
        // notice. A refused click beats a wrong one.
        guard let scale = Self.number(size["scale_factor"]) else {
            throw Refusal.cannotSee("the driver did not report the display scale")
        }
        let shown = Geometry.Shown(width: width, height: height, scale: scale)
        // Present but nonsense is as bad as absent: a waking or locked
        // display has reported scale 0, which `Shown` turns into NaN, and a
        // NaN coordinate in a JSON request kills the daemon outright.
        guard shown.isUsable else {
            throw Refusal.cannotSee("the display reported a size of \(width)x\(height) at scale \(scale)")
        }
        return shown
    }

    // MARK: - Acting

    public func click(labelled label: String, button: String = "left") async -> ExecutionResult {
        do {
            let target = try await frontmostTarget()
            let found = try await elements(of: target)
            guard let match = Self.bestMatch(for: label, in: found, roles: Self.clickableRoles) else {
                return .failed(reason: Self.notFound(label, in: found, app: target.appName))
            }
            guard match.enabled else {
                return .failed(reason: "“\(match.label)” is greyed out right now")
            }
            var args: [String: Any] = ["pid": target.pid, "window_id": target.windowID]
            if button != "left" { args["button"] = button }

            // Web content gets clicked by position, native controls by their
            // accessibility handle.
            //
            // Not a preference — a measured difference. Safari's AXPress on a
            // web button does nothing at all: the driver reports it delivered
            // and the page never sees a click. Chrome's works. Both browsers
            // respond to a real click at the right pixel, so for anything
            // inside a web view that is the route we take. Native controls
            // keep the handle, which survives the window moving.
            CuaDriver.note("click “\(match.label)” role=\(match.role) app=\(target.appName)")
            // One route: the handle from the snapshot taken moments ago, in
            // this same call.
            //
            // It reaches a window that is not in front, on another display,
            // with other windows stacked over it — the driver delivers in the
            // background and steals no focus. Verified against a Safari window
            // buried three layers down while Chrome was frontmost: three fresh
            // handles, three clicks, three landed.
            //
            // Reading the snapshot and using it inside one call is the whole
            // discipline. A handle kept across other work goes stale, and a
            // stale handle is delivered with no error and no effect — which is
            // what briefly convinced me Safari could not be clicked at all,
            // and cost an unnecessary pixel-clicking detour.
            Self.address(match, into: &args)
            _ = try await driver.call("click", args)
            return .ok(reason: "\(button == "right" ? "Right-clicked" : "Clicked") “\(match.label)”")
        } catch {
            return .failed(reason: "\(error)")
        }
    }

    /// The name jev gives the nth unlabelled box on a form.
    ///
    /// A hand-rolled web form routinely exposes boxes with no accessibility
    /// label at all, and an empty name is not something you can send back:
    /// `bestMatch` refuses it, so the reply was "Nothing called “” in
    /// Chrome" — on precisely the forms this feature exists for. The
    /// position IS the address in that case, and both ends agree on this
    /// spelling.
    public static func placeholderName(_ ordinal: Int) -> String { "Field \(ordinal)" }

    /// The name used when even "Field N" is a name the form already uses.
    public static func fallbackName(_ ordinal: Int) -> String { "Unnamed box \(ordinal)" }

    /// The ADDRESS of an unlabelled box, as opposed to its caption.
    ///
    /// Two attempts at this were wrong in opposite directions, both because
    /// the caption was doing double duty as the address. Sending back the
    /// words "Field 1" put it through `bestMatch`, whose prefix and
    /// containment tiers then matched a real box labelled "Field 10" or
    /// "Field 1 (optional)" — a value typed into box 1 written silently
    /// into box 10. Avoiding only EXACT caption collisions does not help,
    /// because those tiers are not exact.
    ///
    /// So the caption stays human ("Field 1") and the address becomes
    /// something no accessibility label can ever equal. Position is the
    /// only truth for a box the Mac does not name, and this says so out
    /// loud instead of hoping a caption survives fuzzy matching.
    /// - Parameter of: how many boxes the form had when the card was built.
    ///   Position is only meaningful against the shape it was counted in:
    ///   a cookie banner or an autocomplete row inserted while you type on
    ///   the phone shifts every box down one, and box 2 becomes box 1. The
    ///   count is the cheapest thing that notices.
    /// - Parameter inWindow: which window the boxes were counted in.
    ///   Position and count alone are not enough: `fill` re-resolves the
    ///   frontmost window every time, so a two-field login page whose
    ///   focus moved to a two-field search box passed the count check and
    ///   typed the password into the wrong app — reported as success.
    public static func positionalAddress(_ ordinal: Int, of total: Int, inWindow window: Int) -> String {
        "jev:box:\(ordinal)/\(total)@\(window)"
    }

    /// Nil unless this is one of jev's own addresses.
    public static func placeholderOrdinal(_ label: String) -> (ordinal: Int, of: Int, window: Int)? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("jev:box:") else { return nil }
        let body = trimmed.dropFirst("jev:box:".count).split(separator: "@")
        guard body.count == 2, let window = Int(body[1]) else { return nil }
        let parts = body[0].split(separator: "/")
        guard parts.count == 2, let n = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (n, total, window)
    }

    public func fill(field label: String, with text: String) async -> ExecutionResult {
        do {
            let target = try await frontmostTarget()
            let found = try await elements(of: target)
            let fields = found.filter { Self.fieldRoles.contains($0.role) }
            // One of jev's own addresses resolves by position and ONLY by
            // position — never falling through to name matching, which is
            // how a value ended up in the wrong box. Anything else is a
            // name the form itself chose, and is matched as a name.
            let match: Element?
            if let address = Self.placeholderOrdinal(label) {
                // The form has to still be the form you were shown. If a
                // box appeared or vanished in between, position no longer
                // means what it meant, and filling by it would put your
                // value in the wrong box — the failure this address was
                // introduced to prevent, arriving by the other door.
                guard address.window == target.windowID, address.of == fields.count else {
                    return .failed(reason: "That is not the form you were looking at any more — ask for it again")
                }
                match = (address.ordinal >= 1 && address.ordinal <= fields.count)
                    ? fields[address.ordinal - 1] : nil
            } else {
                match = Self.bestMatch(for: label, in: found, roles: Self.fieldRoles)
            }
            guard let match else {
                // Never show jev's own spelling to a person. "Nothing
                // called jev:box:3/7" is not a sentence anyone can act on.
                let shown = Self.placeholderOrdinal(label) == nil ? label : "that box"
                // The FIELD names, because this is a fill. `notFound`
                // defaults to clickable roles, which are disjoint from
                // field roles — so a refused fill named the buttons and
                // withheld the one word the person needed.
                return .failed(reason: Self.notFound(shown, in: found, app: target.appName,
                                                     roles: Self.fieldRoles))
            }
            var args: [String: Any] = ["pid": target.pid, "window_id": target.windowID, "value": text]
            Self.address(match, into: &args)
            _ = try await driver.call("set_value", args)
            // The value itself never goes in the reason. Labels are loggable,
            // contents are not — that is why forms are filled from the phone.
            // Same rule as the failure path: jev's own spelling is not a
            // word for a person. An unlabelled box is precisely the case
            // this address exists for, so `match.label` is empty exactly
            // when `label` is "jev:box:2/5".
            let named = match.label.isEmpty
                ? (Self.placeholderOrdinal(label) == nil ? label : "that box")
                : match.label
            return .ok(reason: "Filled “\(named)”")
        } catch {
            return .failed(reason: "\(error)")
        }
    }

    public func type(_ text: String) async -> ExecutionResult {
        do {
            let target = try await frontmostTarget()
            _ = try await driver.call("type_text", [
                "pid": target.pid,
                "window_id": target.windowID,
                "text": text,
            ])
            return .ok(reason: "Typed into \(target.appName)")
        } catch {
            return .failed(reason: "\(error)")
        }
    }

    /// A tap on the phone's picture of the screen. Coordinates arrive
    /// normalised 0…1 because the phone has no idea how big the Mac is.
    public func click(normalisedX x: Double, y: Double, button: String = "left") async -> ExecutionResult {
        do {
            let shown = try await display()
            guard let at = Geometry.pixels(Geometry.Normalised(x: x, y: y), on: shown) else {
                return .failed(reason: "Cannot see the screen well enough to click there")
            }
            var args: [String: Any] = ["scope": "desktop", "x": at.x, "y": at.y]
            if button != "left" { args["button"] = button }
            _ = try await driver.call("click", args)
            return .ok(reason: "Clicked the screen")
        } catch {
            return .failed(reason: "\(error)")
        }
    }

    public func scroll(direction: String, amount: Int) async -> ExecutionResult {
        let allowed = ["up", "down", "left", "right"]
        guard allowed.contains(direction) else {
            return .failed(reason: "Cannot scroll “\(direction)”")
        }
        do {
            var args: [String: Any] = ["direction": direction, "amount": max(1, amount)]
            // Aim the wheel at a point inside the window rather than sending a
            // process-scoped keystroke. Chrome owns a dozen windows, and the
            // driver rightly refuses a key event it cannot prove will land on
            // the right one — "same_pid_keyboard_ambiguity", seen in testing.
            // A wheel event at a position has no such ambiguity, and it is
            // what a mouse would do anyway: scroll what is under the pointer.
            if let target = try? await frontmostTarget() {
                args["pid"] = target.pid
                args["window_id"] = target.windowID
                if target.width > 0, target.height > 0 {
                    args["x"] = target.width / 2
                    args["y"] = target.height / 2
                }
            } else {
                args["scope"] = "desktop"
            }
            _ = try await driver.call("scroll", args)
            return .ok(reason: "Scrolled \(direction)")
        } catch {
            return .failed(reason: "\(error)")
        }
    }

    // MARK: - Reading a form

    /// The fillable fields of the frontmost window, in the order they appear.
    ///
    /// - Returns: at most `limit` fields to show, AND how many there
    ///   actually are. Both numbers matter: the card shows the first
    ///   twelve, but a positional address has to be counted against the
    ///   whole form, because that is what `fill` counts. Returning only
    ///   the truncated list made every field of a fifteen-box form
    ///   permanently unfillable — "that form changed while you were
    ///   typing", forever, on a form that had not changed at all.
    public func formFields(limit: Int = 12) async throws
        -> (shown: [(label: String, secret: Bool, kind: String)], total: Int, window: Int) {
        // Throws rather than returning []. "I could not read the window" and
        // "this window has no fields" are opposite answers, and collapsing
        // them told the phone "nothing fillable here" when the real problem
        // was that jev could not see the screen at all.
        let target = try await frontmostTarget()
        let found = try await elements(of: target)
        let fields = found.filter { Self.fieldRoles.contains($0.role) }
        return (fields.prefix(limit)
                    .map { (label: $0.label, secret: Self.looksSecret($0), kind: $0.role) },
                fields.count, target.windowID)
    }

    /// The labels of everything actionable in front, for handing Jev a closed
    /// choice. This is the list that keeps the classifier honest: it can only
    /// ever pick a control that the driver just confirmed exists.
    public func visibleLabels(limit: Int = 60) async -> [String] {
        await frontmostContext(limit: limit).labels
    }

    /// The frontmost app AND its controls, read together.
    ///
    /// These must come from one snapshot. Asking NSWorkspace which app is in
    /// front and asking the driver for controls is two questions to two
    /// oracles, and they disagree — seen in testing: the log said "Waz" while
    /// the control list was Chrome's. Telling the classifier it is in one app
    /// and handing it another app's buttons is how you get a confident wrong
    /// answer, which is the one failure mode this whole design exists to avoid.
    public func frontmostContext(limit: Int = 60) async -> (app: String?, labels: [String]) {
        if let fresh = await Self.cache.recent() { return fresh }
        guard let target = try? await frontmostTarget(),
              let found = try? await elements(of: target) else { return (nil, []) }
        var seen = Set<String>()
        let labels = found
            .filter { Self.clickableRoles.contains($0.role) || Self.fieldRoles.contains($0.role) }
            .compactMap { seen.insert($0.label).inserted ? $0.label : nil }
            .prefix(limit)
            .map { $0 }
        await Self.cache.store((target.appName, labels))
        return (target.appName, labels)
    }

    /// One spoken command asks what is on screen several times over: once to
    /// pick which reading was really said, once to see whether it names a
    /// button, and once more to give the classifier a closed choice. They all
    /// mean the same instant, so they should cost one look, not three.
    ///
    /// Short on purpose. Long enough to cover a single command end to end,
    /// far too short to still be believed by the time you say the next thing.
    private actor Snapshot {
        private var value: (app: String?, labels: [String])?
        private var takenAt = Date.distantPast
        private let lifetime: TimeInterval = 2.0

        func recent() -> (app: String?, labels: [String])? {
            guard let value, Date().timeIntervalSince(takenAt) < lifetime else { return nil }
            return value
        }

        func store(_ fresh: (app: String?, labels: [String])) {
            value = fresh
            takenAt = Date()
        }
    }

    private static let cache = Snapshot()

    /// Everything pressable in front, numbered, with where it is on screen.
    ///
    /// For the case names cannot solve. Chrome's profile picker offers four
    /// buttons all labelled "Alex"; no amount of saying the name will pick
    /// the third one, and refusing an ambiguous match — correct as that is —
    /// leaves you stuck. Numbers are the way out: the phone draws them over
    /// its picture of the screen and you say the one you want.
    ///
    /// Positions come back normalised against the display, because the phone
    /// is showing a scaled screenshot and knows nothing about Mac pixels.
    public func numberedControls(limit: Int = 30) async throws
        -> [(number: Int, label: String, x: Double, y: Double, w: Double, h: Double)] {
        let shown = try await display()
        let target = try await frontmostTarget()
        let found = try await elements(of: target, limit: 200)

        return found
            .filter { Self.clickableRoles.contains($0.role) || Self.fieldRoles.contains($0.role) }
            .filter { $0.enabled && $0.frame != nil }
            // A number does not need a name. Dropping unlabelled controls
            // made sense for matching by name and is wrong here: the whole
            // reason to put numbers on the screen is to reach something you
            // cannot name.
            .filter { ($0.frame!.width * $0.frame!.height) > 120 }
            // Reading order: down the page, then across, so the numbers run
            // the way the eye does rather than the way the tree does.
            .sorted {
                let a = $0.frame!, b = $1.frame!
                if abs(a.minY - b.minY) > 12 { return a.minY < b.minY }
                return a.minX < b.minX
            }
            // Only what the phone can actually see. A control on the second
            // display has no fraction of THIS one, so it simply has no place
            // to be drawn — Geometry says so by returning nil rather than a
            // negative coordinate that quietly becomes an invisible badge.
            .compactMap { element -> (label: String, box: (x: Double, y: Double, w: Double, h: Double))? in
                guard let box = Geometry.normalised(element.frame!, on: shown) else { return nil }
                return (label: element.label, box: box)
            }
            .prefix(limit)
            .enumerated()
            .map { index, row in
                (number: index + 1, label: row.label,
                 x: row.box.x, y: row.box.y, w: row.box.w, h: row.box.h)
            }
    }

    // MARK: - Matching

    public static let clickableRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXLink", "AXMenuItem", "AXDisclosureTriangle", "AXTab", "AXToolbarButton",
        "AXStaticText", "AXCell", "AXRow", "AXImage",
    ]

    /// Roles that are containers or labels rather than controls.
    ///
    /// They are in `clickableRoles` because a list row genuinely has to
    /// be clickable — but when a row, its cell and its text all carry
    /// the same name, that is ONE thing with three accessibility
    /// wrappers, not three candidates to refuse between.
    public static let wrapperRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText", "AXImage"]

    /// Outermost first, for when every candidate is packaging.
    static let wrapperRank: [String: Int] = ["AXRow": 0, "AXCell": 1, "AXStaticText": 2, "AXImage": 3]

    /// One candidate, or none, from a set that may be the same thing
    /// several times over.
    ///
    /// A row, its cell and its text all carry the same accessible name
    /// as a matter of course, so counting them as rivals refuses a
    /// click that has only one possible meaning. A real control beats
    /// its own packaging; an all-packaging tie resolves outward; two
    /// real controls stay an ambiguity and are refused.
    static func collapseWrappers(_ candidates: [Element]) -> Element? {
        if candidates.count == 1 { return candidates[0] }
        guard !candidates.isEmpty else { return nil }
        // Only ever within ONE name.
        //
        // The premise is "these are the same thing wearing three
        // accessibility wrappers", which holds in the exact tier and
        // not in the prefix tier, where the candidates have DIFFERENT
        // labels. Applied there, "a real control beats its packaging"
        // silently picked a control belonging to another name: asking
        // for "Delete" against a row "Delete Forever" and a button
        // "Delete Everything" pressed the destructive one, where jev
        // used to say what it could see. Two surviving names is an
        // ambiguity, which is the whole point of this function.
        let byLabel = Dictionary(grouping: candidates) { normalise($0.label) }
        guard byLabel.count == 1 else { return nil }
        let controls = candidates.filter { !wrapperRoles.contains($0.role) }
        // A control that TOGGLES is not the packaging of a row.
        //
        // "a real control beats its wrappers" is right for a button
        // wrapped in its own label, and wrong for a Privacy pane, where
        // each row carries a switch that AX names after the app — so
        // "click Safari" would have flipped a permission instead of
        // selecting the row. When both a row and a switch answer to the
        // same name, that is a genuine ambiguity.
        // Every one of these is in `clickableRoles`; listing a role the
        // pool never contains would make the guard dead for it.
        let toggles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXDisclosureTriangle"]
        if controls.count == 1, toggles.contains(controls[0].role),
           candidates.contains(where: { $0.role == "AXRow" }) {
            return nil
        }
        if controls.count == 1 { return controls[0] }
        guard controls.isEmpty else { return nil }
        let ranked = candidates.sorted { (wrapperRank[$0.role] ?? 9) < (wrapperRank[$1.role] ?? 9) }
        guard let outer = ranked.first,
              ranked.dropFirst().allSatisfy({ wrapperRank[$0.role] != wrapperRank[outer.role] })
        else { return nil }
        return outer
    }

    public static let fieldRoles: Set<String> = [
        "AXTextField", "AXSecureTextField", "AXTextArea", "AXComboBox",
    ]

    public static func rect(_ any: Any?) -> CGRect? {
        guard let f = any as? [String: Any],
              let x = number(f["x"]), let y = number(f["y"]),
              let w = number(f["w"] ?? f["width"]), let h = number(f["h"] ?? f["height"])
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// JSON numbers arrive as Int or Double depending on the value.
    public static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    /// Words that mean "do not say this out loud", in the languages a Mac is
    /// most likely to be showing.
    ///
    /// Not English-only. Review caught that "contraseña" and "mot de passe"
    /// sailed through as ordinary text fields, which would have put a real
    /// password on the phone as a dictatable box. Matching is substring over a
    /// lowercased label, so stems cover their own inflections.
    static let secretTells = [
        "password", "passphrase", "passcode", "pass code", "pin", "secret",
        "security code", "cvv", "cvc", "one-time", "one time", "otp",
        "verification code", "auth code", "2fa", "mfa", "token",
        "api key", "private key", "recovery key", "seed phrase",
        // A card number is not a password, but it is just as much a
        // thing you should not say out loud in a room. `FormScanner`
        // already refuses to let a field the MODEL names "card number"
        // be dictated; a form that labels it itself was not covered.
        "card number", "credit card", "account number", "sort code",
        "iban", "routing number", "social security", "ssn",
        // Every one of these was measured as reaching the phone as an
        // ordinary text box, which means it could be dictated aloud.
        "recovery phrase", "mnemonic", "seed words", "backup code",
        "recovery code", "sms code", "authenticator", "confirmation code",
        "totp", "unlock code", "master key", "encryption key", "signing key",
        "security answer", "digit code", "ccv", "cc number", "pwd", "passwd",
        // GitHub's literal 2FA label is "Authentication code", which
        // "auth code" does not match by any of the three paths.
        "authentication code", "two-factor", "two factor", "login code",
        "access code", "backup phrase", "card verification",
        "security question", "memorable word", "maiden name",
        "contraseña", "contrasena", "clave", "senha",
        "mot de passe", "code secret",
        "passwort", "kennwort", "wachtwoord", "sicherheitscode",
        "parola d\'ordine", "codice di sicurezza",
        "lösenord", "adgangskode", "passord", "salasana",
        "пароль", "hasło", "heslo",
        "密码", "密碼", "パスワード", "暗証番号", "비밀번호",
        "şifre", "كلمة المرور", "סיסמה",
    ]

    /// A label reduced to lowercase words, however it was written.
    ///
    /// Three spellings have to come out the same: `accessToken`,
    /// `access-token` and `Access Token`. The case boundary is the hard
    /// one, and it has two shapes — a lowercase or digit followed by a
    /// capital (`userPin`), and the END of an acronym run, which is a
    /// capital followed by a lowercase (`APIKey` is `api key`, but the
    /// `PI` inside it is not a boundary). Splitting only on the first
    /// shape turned `2FA` into `2 fa` and lost the one digit-initial
    /// tell in the list.
    static func flatten(_ label: String) -> String {
        var out = ""
        let characters = Array(label)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else { out.append(" "); continue }
            if character.isUppercase, let last = out.last, last.isLetter || last.isNumber {
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if last.isLowercase || (last.isUppercase && nextIsLower) { out.append(" ") }
            }
            out.append(character)
        }
        return out.lowercased()
    }

    /// Whether a field should never be spoken into.
    ///
    /// A native app marks its password boxes `AXSecureTextField` and that is
    /// the end of it. The web does not: Chrome hands back a plain
    /// `AXTextField` for `<input type="password">`, with no subrole and no
    /// other tell — verified against a real page. Trusting the role alone
    /// would put a password field on the phone as an ordinary text input, and
    /// the voice-fill refusal keys off exactly this flag, so you could dictate
    /// your password out loud into a room.
    ///
    /// So the label gets a say too. Over-marking a field is harmless — you
    /// type it instead of saying it. Under-marking one is not.
    ///
    /// Whole words, though. A bare substring test made "Shipping address"
    /// a secret field, because it contains "pin" — masked on the phone
    /// and refused by voice with "never say it out loud". Over-marking
    /// is safe and it is still annoying; "typing" trips it too.
    public static func looksSecret(_ element: Element) -> Bool {
        if element.role == "AXSecureTextField" { return true }
        let label = normalise(element.label)
        // Only a plain one-word ASCII tell gets the word-boundary test.
        // Everything else is matched as written: "one-time" contains a
        // hyphen, which the tokeniser treats as a separator, and "密码"
        // is not space-delimited at all — so tokenising either of those
        // simply stops them matching. The self-test caught exactly that
        // the moment the boundary rule went in.
        // camelCase is a word boundary, and so is punctuation.
        //
        // "accessToken", "userPin", "securityCode" and "Mot-de-passe"
        // are all ordinary renderings that the tokeniser could not see:
        // a short tell has to BEGIN a token, and in camelCase it never
        // does, while a multi-word tell was matched as a raw substring
        // so a hyphen between the words defeated it. Splitting on the
        // case change, and flattening punctuation to spaces, makes all
        // four spellings the same string this function already knew.
        // From the ORIGINAL label, because `normalise` has already
        // lowercased `label` and a camelCase boundary cannot survive
        // that — which is exactly how the first version of this split
        // did nothing at all.
        let spaced = Self.flatten(element.label)
        // All-caps runs have no boundary to find — "APIKEY" cannot be
        // split without a dictionary — so the de-spaced form catches
        // those against a de-spaced tell.
        let squashed = spaced.replacingOccurrences(of: " ", with: "")
        let words = spaced.split(separator: " ")
        return Self.secretTells.contains { tell in
            let plainWord = tell.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            // A multi-word tell matches against the same flattened form,
            // so "mot de passe" finds "Mot-de-passe" and "API-KEY".
            guard plainWord else {
                return spaced.contains(tell) || label.contains(tell)
                    || squashed.contains(tell.replacingOccurrences(of: " ", with: ""))
            }
            // How much of a token has to match depends on how much
            // the tell is worth.
            //
            // Exact equality narrowed this in the dangerous direction:
            // languages inflect and compound, so Finnish "Salasanasi",
            // Dutch "Wachtwoordbevestiging", plain English "Passwords"
            // and a camelCase-derived "userPassword" all stopped being
            // recognised — and a password box that is not recognised is
            // one the phone will let you say out loud.
            //
            // But plain containment is what made "Shipping address" a
            // PIN field. The length of the tell settles it: a short one
            // is a fragment of too many ordinary words, so it has to
            // begin a token; a long one is distinctive enough to match
            // anywhere inside one. Over-marking costs a person one
            // typed field; under-marking costs them the password.
            // …and against the de-spaced form, which is the only place
            // an all-caps compound or a tell the splitter cut through
            // can still be found. `squashed` was computed for this and
            // then consulted only on the multi-word branch, so
            // "USERPIN" and — worse, because it used to work —
            // "PassWord" came back plain. `flatten` splits between the
            // capitals and nothing put the word back together.
            if words.contains(where: { tell.count >= 6 ? $0.contains(tell) : $0.hasPrefix(tell) }) {
                return true
            }
            //
            // KNOWN LIMIT: an all-caps compound with a SHORT tell —
            // "USERPIN", "SMSOTP" — is out of reach. There is no
            // boundary to split on, and letting a three-letter tell
            // match anywhere inside the squashed form brings back the
            // false positive this rule was written to remove:
            // "shipping" contains "pin". A rarely-written label is the
            // lesser cost, but it IS a cost, and it is the dangerous
            // direction, so it is written down rather than glossed.
            return tell.count >= 6 ? squashed.contains(tell) : squashed.hasPrefix(tell)
        }
    }

    /// Exact label wins, then a whole-word prefix, then containment. Never a
    /// fuzzy score: "Don't Save" and "Save" differ by one word and the wrong
    /// choice loses your document.
    public static func bestMatch(for label: String, in elements: [Element], roles: Set<String>) -> Element? {
        let wanted = normalise(label)
        guard !wanted.isEmpty else { return nil }
        let pool = elements.filter { roles.contains($0.role) }

        // Refuse an ambiguity here too, not just in the prefix tier
        // below. Chrome's profile picker offers four buttons all called
        // "Alex" — this file's own comments use it as the example —
        // and `first(where:)` silently pressed whichever the driver
        // happened to list first.
        //
        // But a row and the text inside it are not two candidates.
        // `clickableRoles` deliberately includes the WRAPPERS —
        // AXRow, AXCell, AXStaticText, AXImage — so that a list item
        // can be clicked at all, and macOS gives the container and its
        // label the same accessible name as a matter of course. A flat
        // count refused "click General" in System Settings with
        // "I can see: “General”, “General”", which is worse than the
        // guess it replaced. So the real control wins over its own
        // packaging, and only a tie BETWEEN CONTROLS is an ambiguity.
        let exact = pool.filter { normalise($0.label) == wanted }
        if !exact.isEmpty { return Self.collapseWrappers(exact) }

        // Never across a negation. This function's own comment below has
        // warned about "Save" becoming "Don't Save" since it was written,
        // and the loose tiers did exactly that: on a two-control surface
        // "Don't Save" is the ONLY thing containing "Save", so the
        // single-candidate rule handed it back. Reachable with free text
        // through the right-click binding, which takes any argument.
        // Only a candidate that ADDS TO THE END of what was asked for.
        // Containment let "Don't Save" answer to "Save" — this file's
        // own comment below has warned about exactly that since it was
        // written — and it read "Discard Invoice" as a match for
        // "Invoice", which is one of two actions, not a narrowing.
        let prefixed = pool.filter {
            normalise($0.label).hasPrefix(wanted) && !Negation.differs(label, $0.label)
        }
        // Collapsed the same way as the exact tier. Without it, "click
        // Sound" in System Settings refused with "I can see: Sound &
        // Haptics, Sound & Haptics, Sound & Haptics" — the same row
        // three times, which is the failure the exact tier was fixed
        // for arriving one tier down.
        if let only = Self.collapseWrappers(prefixed) { return only }

        // Two things match and we cannot tell them apart. Refusing is right:
        // picking one at random is how "Save" becomes "Don't Save".
        return nil
    }

    public static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            // The same fold as the AX matcher. A menu item is titled
            // "Save As…" with the character; a person says or types
            // "Save As...". Without this the two matchers disagree about
            // the same string — the dialog path resolves it and the
            // driver path refuses it — and menu items ending in an
            // ellipsis are the common case for AXMenuItem.
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefer the opaque token, which the driver invalidates when the window
    /// changes underneath us. An index alone can silently point at a different
    /// control after a redraw.
    public static func address(_ element: Element, into args: inout [String: Any]) {
        if let token = element.token {
            args["element_token"] = token
        } else {
            args["element_index"] = element.index
        }
    }

    /// - Parameter roles: what was actually being looked for. A refused
    ///   FILL was suggesting clickable things, and `clickableRoles` and
    ///   `fieldRoles` are disjoint sets — so the list could never contain
    ///   a single field name, and the one word the person needed was the
    ///   one word withheld.
    public static func notFound(_ label: String, in elements: [Element], app: String,
                                roles: Set<String>? = nil) -> String {
        let wanted = roles ?? clickableRoles
        // De-duplicated, like `visibleLabels` already does. A window
        // full of row/cell/text triples spent the whole six-name budget
        // saying the same three things three times each.
        var seen = Set<String>()
        let names = elements
            .filter { wanted.contains($0.role) && !$0.label.isEmpty && seen.insert(normalise($0.label)).inserted }
            .prefix(6).map { "“\($0.label)”" }.joined(separator: ", ")
        if names.isEmpty {
            return "Nothing called “\(label)” in \(app)"
        }
        return "Nothing called “\(label)” in \(app). I can see: \(names)"
    }

    /// The driver's refusal text is precise but written for a machine. The
    /// phone shows this to a person standing in another room.
    public static func humanise(_ reason: String) -> String {
        if reason.contains("ax_window_unresolved") || reason.contains("off_space") {
            return "That window is on another Space or not really in front — switch to it first"
        }
        if reason.contains("stale") {
            return "The window changed while I was looking at it; try again"
        }
        return String(reason.split(separator: ".").first ?? Substring(reason))
    }
}

