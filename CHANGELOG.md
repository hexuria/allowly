# Changelog

## 2026-09-21 — after the scope-first merge

Ten changes that went to `main` directly, without a pull request, in the
hours after #11 was merged. This entry exists so they are reviewable after
the fact: each one says what changed and, more usefully, what was wrong.

Three of the ten fix bugs introduced by the other seven. That is recorded
rather than tidied away, because the pattern — a fix whose own failure mode
is worse than the bug — is the thing worth noticing.

### Aiming a keystroke

- **Pass the aim, do not hold it** (`41dc6eb`). The app a command was
  resolved against was kept in a process-global for the length of that
  command. `JevRuntime` is an actor and an actor suspends at every `await`,
  so two overlapping commands clobbered each other's aim — producing exactly
  the wrong-window keystroke the aim exists to prevent. It also outlived its
  command: the clear lived in `journal()`, and the `model/asked` path returns
  without going through it. It is a parameter now, which cannot be stale and
  cannot be shared.

- **An aim that cannot be taken refuses** (`16e3919`). A keystroke whose
  target would not come forward was logged and then posted anyway, into
  whatever was in front. `bring` returns whether it worked and the four
  typing paths refuse when it did not. The wait went from 300 ms to 600 ms:
  an app that has been swapped out is slow to come forward, and refusing
  because a cold app was slow is its own wrong answer.

- Addressing was eating the address. "In Safari, close tab" strips to "close
  tab" before interpretation, and the journal was recording the stripped
  sentence — so the one line per command that says what was said no longer
  did.

### Permissions and cards

- **A saved "never" survives the move to per-app keys** (`9f08bc4`). Typing
  and clicking moved off the shared `system.keyboard` and `system.pointer`
  keys onto the app they act on. Anyone with a policy saved under the old key
  has it silently stop applying, and the two directions are not the same kind
  of wrong: a `never` that stops applying re-enables something deliberately
  switched off, so it still refuses. A blanket `always` is the hole being
  closed, so it is retired — and said out loud in the log the first time it
  would have applied.

- **The card says why it is asking** (`22a6566`). Every approval card said
  "… has not been allowed yet" whatever had actually stopped the command, and
  only one of six reasons is about permission at all. A half-caught sentence
  therefore raised a card blaming a setting the person had already changed —
  which is how "always allow" came to look broken. Measured twice in one
  evening, on "visit facebook" and "open youtube", both refused by a
  confidence of 0.54 against a floor of 0.55.

### Dialogs that wait

- **Do not withdraw a card while its dialog is on screen** (`823c50f`). A TCC
  prompt went up at 03:57, jev pushed a notification, the card was destroyed
  at 04:02, and a screenshot at 04:07 shows the prompt still there. Five
  minutes is the right life for a card about a moment that has passed; it is
  the wrong life for a macOS permission prompt, which waits indefinitely. The
  sweep now holds a card open while `DialogRegistry.isLive` says its dialog is
  there.

- **Say when a card is being held** (`2aa00bb`). Proving the above worked
  meant proving a negative. There is a positive line in the log now.

- **A dialog whose process has exited is gone** (`5d7127e`). The hold above
  traded one bug for another within the hour. `isLive` treats anything short
  of `invalidUIElement` as alive, which is right for a busy app — AX times out
  while a sheet is plainly still on screen — but a process that has *exited*
  answers with the same code. Such a card was then held forever, and the next
  identical dialog was suppressed as a duplicate of a ghost. The kernel is
  asked before Accessibility now: `kill(pid, 0)` sends nothing and only asks.

### Being able to tell

- **Keep the numbers a decision was made on** (`4b383b2`). The confidence
  floor decides whether a command runs or waits, and the journal held 85 real
  commands without a single number in it — confidences went to the log, and
  the log rotates. The floor could only ever be argued about from memory. The
  journal now keeps confidence, routine and destructive scores, and which of
  the reasons raised a card. Every field is optional, so old entries still
  parse.

### The HID bridge, and hardware nobody owns yet

- **Test the HID path with no board, and fix the bug that found**
  (`c003315`). The remote-click story rests on a board that has not been
  bought, and nothing that talks to it could be checked.

  `scripts/jev_hid_stub.py` supplies the one CircuitPython module a Mac lacks
  — `usb_hid` — as a recorder, and then executes the real
  `firmware/jev-hid/code.py` rather than a copy of it.
  `scripts/fake-hid-board.py` serves that firmware behind a pseudo-terminal,
  which has a genuine path under `/dev`, and `JEV_HID_PORT` points jev at it.
  `make hid-test` runs both halves.

  It immediately found this: every read in `HIDBridge` went through
  `FileHandle.read(upToCount:)`, which cannot read a non-blocking descriptor.
  Against a port with a reply already waiting it threw EAGAIN on all 27
  attempts across 600 ms, while a plain `read(2)` on the same port returned
  the answer on the first try. **The handshake could never have completed:
  the board would have arrived and done nothing.** Reads use `read(2)` now.

  The bridge's assertions went from 18 to 48, covering what was previously
  unreachable: every command string, what a reply means, which `/dev` entries
  are candidates, and the three shapes EAGAIN arrives in. The end-to-end block
  runs only behind an explicit `JEV_HID_PORT`, never against a real board at
  startup — which would jerk the pointer and click something every launch.

### Housekeeping

- **`make clean` actually cleans** (`293df2e`). It ran `swift build --clean`,
  a flag Swift stopped accepting several releases ago. The command exited 64,
  make took the target down with it, and the line that removes the app bundle
  never ran — so a stale `build/Jev.app` survived every clean.

### Still unproven

Honest gaps, so nobody reads the above as more than it is:

- No verified remote press from the phone. Three attempts recorded `Approve`
  while jev logged no press in either `jev.log` or `audit.jsonl`.
- The aim, addressing and the per-app card have never run against a real
  spoken command — each would type or click in live apps.
- A card surviving past five minutes is asserted at the store level but has
  not been watched happen end to end.
