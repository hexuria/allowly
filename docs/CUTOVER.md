# Cutover plan — Cua + Chrome, generative forms on the phone

Consolidates issues [#2](https://github.com/hexuria/allowly/issues/2),
[#3](https://github.com/hexuria/allowly/issues/3), [#4](https://github.com/hexuria/allowly/issues/4),
[#5](https://github.com/hexuria/allowly/issues/5), plus two things those issues do not
cover: the phone-side generative form UI, and the pointer rework.

Decisions taken, which override the issues where they disagree:

| Question | Decision |
|---|---|
| Permission cards | **Keep.** What dies is *targeting* (hints, select-N, the AX walk), not the human gate. An agent doing unattended multi-step work is when you most want a checkpoint. |
| json-render | **Spec format only.** Adopt the JSON contract, render it with vanilla JS. No React, no build step. |
| Backend order | **Superseded — #3 is closed into #5.** See below: Cua Driver can attach to the real Chrome profile, so the separate Python sidecar is not needed. |

---

## Review of the issues as written

What is right, and worth keeping:

- **"Remove first" (#4) is the correct discipline.** Two observe/act stacks is worse
  than either alone. The bucket A / bucket B split is also right: A is safe today,
  B genuinely cannot land before #5 is green.
- **"If Jev would have to generate, we are using it wrong."** Closed choice or noul,
  never selectors or coordinates. This is the strongest invariant in the whole epic
  and every new call site should be held to it.
- ~~**Catching that Cua `browser_prepare` is an isolated profile** is a real trap
  avoided.~~ **This turned out to be false, and it was the load-bearing reason for
  #3 existing at all.** CuaDriver 0.23.2's `browser_prepare` takes a `pid` for
  "an existing process or existing-profile attachment", gated behind an explicit
  `--grant existing-profile`. So Gmail and a logged-in cart *can* run there, and
  #3's Python sidecar buys nothing. Verified against the installed driver, not
  the documentation.
- Acceptance criteria are testable, including the `git grep` one.

What I disagree with or would change:

1. **`/api/permission` is buried as a "gap" and should be item zero.**
   `hooks/jev-permission-hook.sh:32` posts to `/api/permission`. There is no such
   route in `Sources/JevServer/Router.swift` — verified by grep. So the Claude Code
   integration, which is the README's lead use case, cannot work at all today. It
   needs no Cua, no sidecar, no browser: a route, `Policy`, `JevDecider`, and the
   cards that already exist. Ship it first.

2. **Line count will fall; operational complexity will rise.** Honest numbers:
   the bucket A+B files total 1,367 lines of the 10,299 lines of Swift, and #4
   correctly says not all of `JevIntent`/`FormScanner` dies. Against that, #3 adds a
   **Python sidecar** that has to be packaged into a signed `.app`, supervised as a
   second process, and given Chrome remote-debugging; #5 adds a dependency on
   **CuaDriver.app** being installed and separately granted Accessibility and Screen
   Recording. Net Swift lines go down. "Things that must be installed and running"
   goes from one to three. That is a real trade and should be made with eyes open.

3. **The naming collision is worse than #2 admits.** "Jev" is now this daemon,
   TypeSafe's classifier, *and* json-render's composition API. Three things in one
   word, two of them in the same request path. Convention: `jevd` for the daemon,
   `TypeSafe` for the classifier in prose, `Spec` for json-render output. Never bare
   "Jev" in a new identifier.

4. **#3's 90-second budget and "leave the tab open" need a card, not a timeout.**
   macbrow can afford to give up silently; we have a phone in your pocket. A web task
   that stalls should raise a card saying what it got stuck on, not just stop.

---

## Order of work

### 0. Now — no dependencies

- [x] **Pointer rework** (this PR). Simple bigger cursor, drag to aim, explicit
      Click / Double / Right-click, double-tap and pinch to zoom, swipe to scroll.
      No gesture presses anything by accident any more.
- [x] **`/api/permission`** route → policy → card → bounded wait → fail closed.
      Three separate breaks, all fixed: no route existed; the hook posted to 8080 while
      the daemon listens on 8787; and the hook read the Keychain while the daemon writes
      the token to a file. Verified through the real hook script: policy `always` answers
      in 15ms with no card, `never` denies, and an unset policy raises a card that the
      phone can answer mid-request.

### 1. #4 bucket A — done

`JevPlan.swift` (93) and its call at `Runtime.swift:333`; `resolveGuideNoun`
(`main.swift:309`, called at `:415`); the hint `Command` cases and their Phrasebook
phrases (83 references across 6 files); `type_text` taking the whole transcript.
Plus the PWA half: `renderHints`, `outlineHint`, `#hintLayer`, `.hint-box`,
`.hint-tag` — the overlay dies with the commands that drive it.

After this, "click the blue button" still works through the AX `click_control` path
until bucket B. Unknown multi-step speech fails closed instead of inventing a plan.

### 2. #3 Chrome — **closed, absorbed into #5**

No Python sidecar, no `jev-ultrafast`, no second runtime to package into a signed
`.app`. The driver already reaches web content: `browser_navigate`, `browser_click`,
`browser_type`, `browser_dialog` and friends, plus ordinary `get_window_state` on a
browser window, which returns web elements with `in_web_content: true`.

What this avoided: a Python 3.11 dependency on a Mac running 3.9, a second process
under supervision, and the notarisation problem of shipping an unsigned interpreter
inside `Jev.app`. "Things that must be installed and running" stays at **two**
(`jevd` and `cua-driver`) instead of going to four.

Checkout / password / 2FA / low confidence still raise a card, never a spoken yes —
that rule was never about which backend does the clicking.

### 3. Generative forms on the phone — done, ahead of #3

This did not have to wait for the browser backend: `FormScanner` already enumerates the
fields of the frontmost window, so `Runtime.broadcastForm` now emits a **Spec** and the
phone renders it natively. When #3 lands, a DOM-derived field list emits the same shape
and the phone learns nothing new.

The Mac sends:

```json
{ "state": { "email": "", "plan": "pro" },
  "root": "form",
  "elements": {
    "form":  { "component": "Panel",  "props": { "title": "Sign in" }, "slots": { "children": ["email","plan","go"] } },
    "email": { "component": "Input",  "props": { "label": "Email", "$bindState": "email" } },
    "plan":  { "component": "Select", "props": { "label": "Plan", "options": ["pro","team"], "$bindState": "plan" } },
    "go":    { "component": "Button", "props": { "label": "Sign in", "action": "submit" } } } }
```

The phone renders that natively — real inputs, real keyboard, real select — instead
of you poking at a JPEG of someone else's form. Tap a field to focus it, then say
*"type andres"* or *"choose pro"*; the field id comes from the focus, the value comes
from a **span-select** over the utterance (the missing Jev call in #2's audit), so
"type andres" never types the word "type".

Renderer: six components (Panel, Heading, Input, Select, Switch, Button), two binding
forms (`$state`, `$bindState`), one action channel. Roughly 120 lines of vanilla JS.
Secrets keep the existing path — typed on the phone, never spoken, never logged.

### 4. #5 Cua + #4 bucket B — done, same PR

New `Sources/JevCua/`: `CuaDriver` (an actor over `cua-driver call`), `CuaBackend`
(jev's operations expressed in driver tools), `CuaSelfTest`.

Deleted: `Hints.swift` (187), `HintScope.swift` (126), ~476 lines of accessibility
walk out of `JevIntent.swift` (813 → 336), ~82 out of `FormScanner.swift` (151 → 62),
`/api/hints`, `AppProfiles.guideNouns`. Kept, as planned: `Pointer`,
`Keystrokes`, `ScreenCapturer`, the dialog watcher, TCC honesty — and
`/api/controls`, which an earlier draft of this document listed as
deleted. It is not: the handler is registered in `Router.swift` and the
phone calls it to draw the numbered badges. The Numbers feature is the
one thing that would have stopped working if the plan had been followed
literally.

Honest line accounting, because an earlier draft of this document claimed a fall to
~9,700 and that was measured before the HID bridge landed:

| | lines |
|---|---|
| targeting machinery removed | **−976** (Hints 187, HintScope 126, JevPlan 93, JevIntent −448, FormScanner −90, guideNouns −24, routes −8) |
| `Sources/JevCua/` added | +792 |
| HID bridge + its test added | +233 |
| **Swift total** | **10,299 → 10,270** |

So the total is flat, and saying "we deleted a thousand lines" would be a half-truth.
What actually changed is *which* thousand: 976 lines of "descend the tree and guess
which node the human meant" are gone, and what replaced them either refuses honestly
or is a capability that did not exist before.

Five things only real hardware could teach us, each now covered by an assertion:

1. **Click coordinates are Retina screenshot pixels; everything else is points.**
   A factor of two. Every tap from the phone would have landed in the top-left
   quadrant. Proven by clicking one button at 1× (nothing) and 2× (it fired).
2. **Chrome exposes `<input type="password">` as a plain `AXTextField`** — no
   secure role, no subrole. Trusting the role would have put a password field on
   the phone unmarked, where it could be dictated aloud.
3. **A snapshot handle goes stale silently.** Used after other work it is
   delivered with no error and no effect. This produced a wrong conclusion that
   survived into a first draft — "Safari's AXPress does nothing on web content",
   and a whole WebKit pixel-clicking special case built on top of it. It was a
   stale handle, not Safari. Retested with a fresh snapshot: three out of three
   landed. The rule is to read the snapshot and use it inside one call, which is
   what `click(labelled:)` does.
4. **Nothing has to be in front.** The driver delivers in the background and
   steals no focus: a Safari window buried three layers down, on a second
   display, with Chrome frontmost, clicked correctly. `background_input` on a
   window state lists the routes it will accept — `accessibility`,
   `window_pointer`, `pid_keyboard`. This removed a `bring_to_front` call, an
   occlusion check and 64 lines of pixel machinery that only existed because of
   the stale-handle mistake above.
5. **`list_windows` order is not z-order**, and most entries are untitled
   off-screen surfaces. Filter to titled + on-screen + on the current Space, then
   take the **lowest** `z_index` — verified by raising a window with AppleScript
   and watching its `z_index` fall from 137 to 75.

### 5. #1 HID bridge — software done, waiting on a $5 board

Cua's clicks are synthetic too, so consent sheets still need real hardware. The
code for it is written and its no-hardware path is live:

- `firmware/jev-hid/boot.py` — composite USB descriptor: HID keyboard plus a mouse
  declared **absolute** over 0…32767, so jev says "go here" instead of
  dead-reckoning. The descriptor has to be built in `boot.py`, before USB comes up.
- `firmware/jev-hid/code.py` — a line protocol over the CDC serial port on the same
  cable: `MOVE`, `CLICK`, `DRAG`, `SCROLL`, `KEY`, `PING`.
- `Sources/jevd/HIDBridge.swift` — finds `/dev/cu.usbmodem*`, and only adopts a port
  that answers `PING` with the firmware's own banner, so jev never starts writing
  mouse commands into somebody's 3D printer. `Pointer.perform` and `Pointer.scroll`
  prefer it and fall back to `CGEvent` the moment a write fails.

With no board attached — the state of every Mac today — `isAttached()` is false,
everything takes the `CGEvent` path exactly as before, and the consent-sheet refusal
stays honest. That fallback is asserted at every start.

**Pointer only.** `HIDBridge.key` speaks the wire protocol but has no callers:
`Keystrokes` addresses keys by macOS virtual keycode and the firmware wants USB
HID usage IDs, and translating between them is a table, not a rename. So with a
board attached, a consent sheet you can answer by clicking becomes reachable and
one that needs Tab or Return does not.

Still unverified, and unverifiable without the part: that a consent sheet actually
accepts the board's click. Expected, since the Mac cannot tell it from a mouse.

---

## What does not change

Tailscale pairing, the permission cards and their policy store, TCC `handoffOnly`
honesty, `Pointer` for your finger, Phrasebook shortcuts, SpeechRepair, secrets never
going through speech.
