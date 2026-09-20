# The screen model — one contract for geometry, identity and honesty

Written after a day in which roughly a dozen separate-looking bugs turned out
to be four. Every one of them was jev being confidently wrong about *which
screen, which window, which coordinate space, or whether anything happened*.
Fixing them one at a time is what produced the day; this is the alternative.

## What actually broke, and why it kept happening

| Symptom | Real cause |
|---|---|
| Every phone tap landed in the top-left quarter | Clicks are addressed in Retina **pixels**; sizes are reported in **points** |
| Badges drawn over nothing, count said 30 | Controls were on the **second display**, normalised outside 0…1 |
| Chrome "showed nothing" | jev used Chrome's frontmost window — on the **other display** |
| …and again after the first fix | Off-display window overlapped the visible one by **one pixel** |
| Pointer impossible to find in full screen | Aim mapped to the **element box**, not the **painted picture** inside it |
| Badges stayed put while the picture zoomed | Zoom is a transform on the **image**; the overlay is pinned to the **frame** |
| "Type hello" said ok, typed nothing | Wrong argument key, and a tool error read as success |
| "Nothing pressable on screen" for an hour | A refusal arrived inside a **successful envelope** |
| "show guides" did nothing | Show and hide sent the **same message**; the phone toggled |

Four root causes, not nine:

1. **Coordinate spaces are not interchangeable** and nothing enforced that.
   Points, Retina pixels, normalised 0…1, window-local, element-box and
   painted-picture all appear in this codebase and several are numerically
   equal on a single non-Retina display — so mistakes stay invisible until
   someone plugs in a second monitor.
2. **"The screen" was never defined.** Frontmost *app*, frontmost *window*,
   the window the *phone is showing*, and the *display* that picture comes
   from are four different things that were used interchangeably.
3. **Overlays did not share the picture's geometry.** The pointer, the number
   badges and the image each had their own idea of where the picture was.
4. **Failure could look like success.** `ok` meant "the message was carried",
   not "the thing happened", and nothing checked the difference.

## Goal

**Everything jev draws on the picture points at the pixel it claims, on every
display, at every zoom — and when it cannot, it says so.**

Concretely: a control's badge, the pointer, and a click all resolve to the
same Mac pixel, and any command that cannot be delivered reports why instead
of reporting success.

## The contract

One source of truth for geometry, stated once and obeyed everywhere.

**Spaces, and the only legal conversions**

| Space | Units | Where it comes from |
|---|---|---|
| `screenPoints` | points, origin top-left of the **shown display** | `get_screen_size`, element `frame`, window `bounds` |
| `screenPixels` | points x `scale_factor` | the only space a click may be addressed in |
| `normalised` | 0…1 across the **shown display** | everything crossing the wire to the phone |
| `pictureRect` | viewport px of the **painted image** | `imageRect()` — never the element box |

Rules:

- Nothing crosses the wire except `normalised`. The phone knows no Mac pixels.
- `normalised` is always against the **shown display**, never a window.
- A click converts `normalised -> screenPixels` in exactly one function.
- Anything positioned over the picture is placed from `pictureRect`, in
  viewport coordinates, and redrawn whenever the picture moves. Percentages of
  the frame are forbidden: the frame does not move when the image zooms.

**Identity**

- *The shown display* is the one being streamed. Everything is relative to it.
- *The target window* is the frontmost window **whose centre is on the shown
  display**. Not the frontmost window; not merely one that overlaps.
- If there is no such window, that is a refusal with a reason, not an empty
  result.

**Honesty**

- A driver reply is a failure if `isError`, if it carries a `refusal`, or if
  `status == "refused"` — checked before the payload is read.
- An empty list and an unreadable screen are different answers and must be
  reported differently.
- A command reports what happened, never what was attempted.

## Constraints

- **No new processes.** `jevd` and `cua-driver`; that is the budget.
- **No accessibility walk comes back.** Observation goes through the driver.
- **Nothing is drawn on the Mac.** Overlays are the phone's, over its own
  screenshot, so what you see is what the Mac looks like.
- **Approval gates stay.** Nothing here widens what can run unattended.
- **Secrets are never spoken, logged, or put in a reason string.**
- **No build step on the phone.** Vanilla JS, no framework, no bundler.
- **Signing identity is fixed** (one Developer ID team, set as `APPLE_TEAM_ID`
  in an untracked `.env`) or TCC grants die.

## Limitations — things this cannot fix

- **One display at a time.** The phone is shown one display; windows on the
  other are refused with a reason, not reached. Streaming both is a separate
  piece of work and is not planned.
- **Accessibility does not see everything.** Some surfaces expose nothing —
  Chrome's profile picker tiles came back unlabelled, and a tour overlay
  produced 470 elements with no "Skip" among them. Where AX is blind, the
  answer is the pointer, not more parsing.
- **Keystrokes cannot be verified cheaply.** ⌘W reports delivery, not effect.
  Verification means comparing the screen before and after, which costs a
  round trip.
- **iOS will not give a web page true full screen.** Only installation to the
  home screen removes Safari's bars.
- **Consent dialogs remain out of reach** — TCC sheets and Chrome's
  remote-debugging prompt both refuse synthetic input by design. That is #1,
  and it needs the USB board.

## Expectations — what "done" means

Each of these is a check that runs at start, or a measurement that can be
repeated, not an opinion.

1. Numbers, pointer and clicks agree on the same Mac pixel at 1x, at 5x, on
   either display, in full screen and windowed. *Asserted by placing a badge
   at a known fraction and reading back its position.*
2. No overlay is ever positioned as a percentage of the frame. *Grep.*
3. Every driver refusal surfaces as a failure with its message. *Asserted
   offline against captured refusal payloads.*
4. Every command produces exactly one journal line carrying route, result,
   duration and the app in front. *Already true; keep it true.*
5. A command that cannot be delivered says which of "nothing there", "cannot
   see the screen", or "not on this display" applies.
6. `close tab` and its siblings report whether the effect landed. *Blocked on
   the verification decision below.*

## Order of work

1. **Land the geometry contract as code, not prose** — one `Geometry` type
   with the four spaces and explicit conversions, so a points-to-pixels
   mistake stops compiling rather than shipping.
2. **Effect verification** for commands that claim to change something: hash a
   small region of the screen before and after, write the answer into the
   journal's `verified` field. This is what closes `close tab`.
3. **One refusal vocabulary** so the phone can say the right sentence for each
   of the three "nothing happened" cases.
4. Only then: new capability.

## The honest note

Most of today was spent fixing symptoms in the order they were noticed, each
fix verified in isolation and several of them wrong for reasons the next bug
revealed. Two were actively harmful — a WebKit pixel-clicking special case
built on a stale-handle misreading, and a screen-beats-vocabulary rule that
quietly took `save`, `back` and `find` away from the Phrasebook. Both were
deleted once measured properly.

The pattern is not bad luck. It is what happens when four different parts of a
program each hold their own idea of where the screen is. This document exists
so the next change has one idea to agree with.
