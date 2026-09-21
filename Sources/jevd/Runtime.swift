import Foundation
import AppKit
import JevCore
import JevAX
import JevCapture
import JevDecide
import JevServer
import JevCua
import JevWeb

/// Owns the running system and connects the parts.
///
/// Everything else in this project is a component that does one thing. This is the
/// only place the actual product behaviour exists: a dialog appears, a decision is
/// made, and either a button is pressed or the phone is asked.
actor JevRuntime {
    private let policy: Policy
    private let store: ApprovalStore
    private let executor: CommandExecutor
    private let pipeline: DecisionPipeline
    private var server: HTTPServer?

    private var watcher: DialogWatcher?
    private var sockets: [WebSocketSession] = []
    /// Commands parked awaiting a yes/no from the phone, by approval id.
    /// A parked command, and the sentence that asked for it.
    ///
    /// The sentence is kept because the card path runs the command much
    /// later, and an ambiguity discovered then has to be able to say
    /// what the person actually asked for. Without it the stored
    /// "what you said" became jev's own refusal, and the next approval
    /// card read: You said "There are 3 things called Follow in
    /// Chrome — say which one, like number two → number two".
    private var pendingCommands: [String: (command: Command, said: String,
                                          saidIsPrivate: Bool, aim: Aim?, key: String?)] = [:]
    /// Cards that only report something. Tapping one must not be mistaken for
    /// answering a dialog: the fallback in `onDecide` turns any unclaimed id
    /// into a `pressButton`, which would go looking for a button on screen
    /// that was never there.
    /// How long a mid-task question waits. Two minutes: long enough to pick
    /// up a phone, and well inside the store's five-minute expiry so the wait
    /// can never outlive the card.
    static let webConsentPolls = 240

    private var webReports: Set<String> = []
    /// Mid-task questions from a browser task that are on the phone right
    /// now, and the answers that have come back.
    ///
    /// Polled, exactly as `awaitedPermissions` is, and for the reason written
    /// there: `withCheckedContinuation` is not cancellation-aware and hung
    /// every request. The wait is long because a person has to notice a
    /// notification and pick up a phone — but bounded well under the store's
    /// five-minute expiry, so it can never outlive the card it is waiting on.
    private var awaitedWebConsent: Set<String> = []
    private var webConsentAnswers: [String: String] = [:]
    /// Permission requests from the Claude Code hook that are on the phone
    /// right now, waiting for a thumb, and the answers that have come back.
    ///
    /// Polled rather than raced with a continuation. The first version used
    /// withTaskGroup and hung every request for the full curl timeout: the
    /// `where` clause skipped the timeout task's nil instead of ending the
    /// loop, and withCheckedContinuation is not cancellation-aware, so the
    /// group waited forever on a child that could never finish. Polling an
    /// actor's own dictionary has none of those edges.
    private var _pendingArgument: (phrase: String, asked: Date)?
    private var lastDecisionNonce: Nonce?
    private var seenNonces: [String: Date] = [:]
    /// Requests jev is pressing a button for right now.
    ///
    /// The auto-press path has to put the request in the store before it
    /// presses, because that is where the executor looks it up — which
    /// means `/api/pending` can hand the card to a phone mid-press. On a
    /// beachballed app the AX walk takes seconds, so foregrounding the
    /// app and tapping Allow in that window pressed the same button a
    /// second time, and the second press landed on whatever replaced the
    /// dialog.
    private var pressingNow: Set<String> = []
    private var awaitedPermissions: Set<String> = []
    private var permissionAnswers: [String: String] = [:]
    /// How the phone should draw the current numbers: bare numbers by default,
    /// outlines only when asked. Eighty boxes over a screenshot hide the thing
    /// you are trying to look at.

    init(policy: Policy, store: ApprovalStore, executor: CommandExecutor) {
        self.policy = policy
        self.store = store
        self.executor = executor
        self.pipeline = DecisionPipeline.standard(policy: policy)
    }

    // MARK: - Lifecycle

    func start(port: UInt16 = 8787) async {
        JevLog.write("[jev] runtime.start entered")

        // Keychain access can put a system dialog on screen. Doing it here, off
        // the main thread and after the run loop is up, keeps it from wedging
        // launch the way it does when called before NSApplication.run().
        let token = KeychainManager.loadOrCreatePairingToken()
        JevLog.write("[jev] pairing token ready")

        let server = HTTPServer(
            config: HTTPServer.Config(bearerToken: token, webRootPath: Self.webRoot())
        )
        self.server = server
        registerRoutes(on: server)
        JevLog.write("[jev] routes registered")

        do {
            try await server.start(on: port)
            // What it bound, not what it would like to have bound.
            // `findBindAddress` returns loopback unless JEV_BIND_TAILNET=1,
            // because `tailscale serve` terminates TLS and proxies to
            // 127.0.0.1 — but this line printed the tailnet address
            // regardless, and it is the line someone reads when pairing
            // is not working.
            let host = await server.boundAddress() ?? "an address it did not report"
            JevLog.write("[jev] Server listening on \(host):\(port)"
                + (host == "127.0.0.1" ? " (tailscale serve fronts it)" : ""))
            // Print the link outright. Reconstructing it by hand from a token
            // file is how the last pairing broke.
            // The same URL the menu bar hands out — an https MagicDNS origin
            // when serve is up. The old line hardcoded http://<ip>:<port>,
            // which is not a secure context and so cannot do voice or push.
            JevLog.write("[jev] Pair your phone — the full link with its token is in the menu bar: "
                + Tailnet.loggableURL(token: token, localPort: port))
        } catch {
            JevLog.write("[jev] Server failed to start: \(error)")
        }

        if await pipeline.usesRemoteDecider {
            JevLog.write("[jev] Decider: Jev (TYPESAFE_API_KEY present)")
        } else {
            JevLog.write("[jev] Decider: local policy only (no TYPESAFE_API_KEY). Anything policy cannot settle goes to your phone.")
        }

        // Speech recognition is its own TCC permission. Without asking, every
        // transcription fails with an authorization error and the phone just
        // sees "failed to process voice command".
        //
        // Asking without the usage string in Info.plist does not fail —
        // macOS kills the process, `EXC_CRASH` with
        // `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`. The app bundle has
        // the key (`scripts/build-app.sh`), the bare `.build/debug/jevd`
        // does not, so running the binary directly aborted a second or
        // two after printing "self-tests: pass" — which is exactly how
        // this project verifies a build, and it looked like the daemon
        // had started fine.
        if Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil {
            Transcription.requestSpeechAuthorization()
        } else {
            JevLog.write("[jev] no NSSpeechRecognitionUsageDescription in this binary — "
                + "skipping the speech permission (voice will not transcribe). Run the app bundle for that.")
        }

        // Start the reaper BEFORE the Accessibility guard.
        //
        // The server is already listening by now and /api/command already
        // works, so spoken commands raise approvals whether or not
        // Accessibility was granted. With the sweep behind the guard, the
        // only thing that removes an expired request never ran: the store
        // grew for the life of the process, and a three-hour-old card was
        // still answerable.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.sweepDeadDialogs()
            }
        }

        guard AccessibilityPermission.isTrusted() else {
            JevLog.write("[jev] Accessibility is not granted, so no dialogs can be seen or pressed.")
            // Ask macOS to show the real prompt rather than only logging. This
            // also registers the app under its current code signature, which a
            // stale entry left over from an earlier signing identity does not.
            _ = AccessibilityPermission.requestTrust()
            JevLog.write("[jev] Requested Accessibility. Approve it, then relaunch Jev.")
            return
        }

        DialogWatcher.log = { JevLog.write("[jev] \($0)") }
        CommandExecutor.onInputRequested = { [weak self] field, secret in
            guard let self, self.hasConnectedPhone else { return false }
            Task { await self.broadcastInputRequest(field: field, secret: secret) }
            return true
        }
        CommandExecutor.onFormFound = { [weak self] fields in
            guard let self, self.hasConnectedPhone else { return false }
            Task { await self.broadcastForm(fields) }
            return true
        }
        CommandExecutor.onNumbersRequested = { [weak self] on in
            // Its two siblings both refuse when nothing is listening; this
            // one returned Void and so always "succeeded", broadcasting to
            // an empty socket list and reporting "Numbers on screen".
            guard let self, self.hasConnectedPhone else { return false }
            Task { await self.broadcastNumbers(on) }
            return true
        }
        CommandExecutor.onWebProgress = { [weak self] step, operation, target, isRetry, finished in
            guard let self else { return }
            Task { await self.broadcastWebProgress(step: step, operation: operation,
                                                   target: target, isRetry: isRetry,
                                                   finished: finished) }
        }
        CommandExecutor.onWebConsent = { [weak self] label, picture in
            guard let self else { return .no }
            // Nothing to ask with. Refusing is the only honest answer: a task
            // must never treat "could not ask" as "was allowed".
            guard self.hasConnectedPhone else { return .noAnswer }
            return await self.askWebConsent(about: label, picture: picture)
        }
        CommandExecutor.onWebReport = { [weak self] title, body, picture in
            guard let self, self.hasConnectedPhone else { return false }
            Task { await self.reportWebOutcome(title: title, body: body, picture: picture) }
            return true
        }
        let watcher = DialogWatcher { [weak self] request in
            guard let self else { return }
            Task { await self.handle(request) }
        }
        self.watcher = watcher
        watcher.start()
        // The watcher's focus and launch events now feed the scope instead
        // of being dropped when the window is not a dialog.
        Task { await ScopeStore.shared.start() }
        JevLog.write("[jev] Watching for dialogs.")

    }

    // MARK: - The loop

    /// May a decider press this button with nobody watching?
    ///
    /// Returns the reason it may not, or nil.
    ///
    /// `Policy.evaluate` already refuses to auto-answer anything above
    /// `maxAutoApprovableRiskLevel`, which is `.low` — but it is the
    /// LOCAL decider, and by the time the remote one is asked, the local
    /// one has already returned `.askHuman` and stepped out of the way.
    /// So the remote `.allow` went straight to a press, gated only by
    /// `dangerousButtonLabels`, and could press "Discard", "Don't Save",
    /// "Revert", "Overwrite", "Move to Trash", "Restart", "Log Out" or
    /// plain "Allow" with nobody in the loop. Every one of those is
    /// rated high precisely so a PERSON is asked first; a model is not
    /// a higher authority than the person it is standing in for.
    ///
    /// The test is on the chosen button, not on every option: what
    /// matters is what is about to be pressed.
    /// Does this reason string carry the typed value back, in any form
    /// a driver is likely to echo it in?
    ///
    /// Verbatim, case-folded, whitespace-stripped, and any run of it
    /// long enough to matter — a reason that quotes the first dozen
    /// characters of a password has still leaked the password.
    static func reasonEchoes(_ value: String, in reason: String) -> Bool {
        guard !value.isEmpty else { return false }
        let fold: (String) -> String = { $0.lowercased().filter { !$0.isWhitespace } }
        let needle = fold(value)
        let haystack = fold(reason)
        guard !needle.isEmpty else { return false }
        if haystack.contains(needle) { return true }
        // A truncated echo. Eight characters is short enough to catch a
        // clipped secret and long enough that an ordinary word shared
        // between the value and jev's own wording does not trip it.
        let window = 8
        guard needle.count > window else { return false }
        var start = needle.startIndex
        while let end = needle.index(start, offsetBy: window, limitedBy: needle.endIndex) {
            if haystack.contains(needle[start..<end]) { return true }
            start = needle.index(after: start)
        }
        return false
    }

    private func refuseToAutoPress(
        _ request: ApprovalRequest, optionId: String, by source: DecisionSource
    ) async -> String? {
        guard let chosen = request.options.first(where: { $0.id == optionId }) else {
            return "\(source) named a button that is not on this dialog."
        }
        if chosen.riskLevel > policy.maxAutoApprovableRiskLevel {
            return "\(source) chose “\(chosen.label)”, which is not one jev presses on its own."
        }
        // …and "not recognised as dangerous" is not the same as safe.
        // `risk`'s dangerous words are English; a decider was free to
        // press `Empty Bin` on an en_GB Mac, or `Löschen` on a German
        // one, with nobody watching. Unattended pressing now needs a
        // positive match.
        guard DialogWatcher.isKnownSafeLabel(chosen.label) else {
            return "\(source) chose “\(chosen.label)”, and jev does not press what it "
                + "cannot recognise as harmless."
        }
        return nil
    }

    /// A dialog appeared. Decide what to do with it.
    private func handle(_ request: ApprovalRequest) async {
        // An explicit "Never allow" for this app is the one case where a
        // dialog should not reach you. Policy no longer denies merely-unknown
        // apps, so this is what keeps the noisy ones quiet.
        let bundleId = request.originatingApp.bundleIdentifier
        // `mode`, not `effectiveMode`. The comment above says "an
        // EXPLICIT 'Never allow' for this app", and `effectiveMode`
        // returns `.never` for every app with no entry once the global
        // default is "Block everything except what I have allowed". So
        // choosing that on the settings sheet — meaning it to govern
        // spoken commands — silently dropped every save sheet and every
        // "Leave site?" on the Mac, with one log line and no card.
        // `decidePermission` already gets this right.
        if AppPolicyStore.shared.mode(for: bundleId) == .never, !request.handoffOnly {
            JevLog.write("[jev] ignoring dialog from \(request.originatingApp.name) — set to never")
            return
        }

        // Handoff-only requests (TCC consent sheets) are never pressed,
        // whatever a decision would have said — macOS ignores synthetic
        // input on them. So the decision is not asked for.
        //
        // This used to sit AFTER the pipeline call, which meant every
        // system permission prompt had its title and body sent over the
        // network to the decider, and jev then waited out the 1.5-second
        // timeout for an answer these four lines throw away. The last
        // text on the screen that should leave the Mac for no reason is
        // a permission prompt.
        if request.handoffOnly {
            // Say what it is, not where it cannot be answered. The old note
            // read "needs you in Screen Sharing", which sounds like jev is
            // asking for a Screen Sharing permission — the opposite of the
            // truth. It means: walk to the Mac, because nothing remote can
            // press this, Screen Sharing included.
            await escalate(request, note: "A macOS permission prompt. Only a press at the Mac itself answers it.")
            return
        }

        // "Ask me about anything I have not already decided" is a
        // setting the person chose, and the dialog path was not reading
        // it — only the per-app override. So with the global set to
        // ask, a dialog from an app with no entry still went to the
        // remote decider, which could answer it. The copy on the
        // settings sheet said otherwise in so many words.
        if AppPolicyStore.shared.mode(for: bundleId) == nil,
           AppPolicyStore.shared.globalMode == .ask {
            await escalate(request, note: "you asked to be asked about everything")
            return
        }

        let decision = await pipeline.decide(request: request, dialogText: request.bodyText)
        JevLog.write("[jev] dialog “\(request.title)” from \(request.originatingApp.name): "
            + "\(decision.value) by \(decision.source) — \(decision.reason)")

        switch decision.value {
        case .allow:
            guard let optionId = decision.chosenOptionId else {
                await escalate(request, note: "jev could not work out which button to press — your call.")
                return
            }
            if let blocked = await refuseToAutoPress(request, optionId: optionId,
                                                     by: decision.source) {
                await escalate(request, note: blocked)
                return
            }
            // The executor looks the request up in the store, and on this
            // branch nothing had ever put it there — only `escalate` adds.
            // So every auto-press failed with "Request not found", the
            // whole auto-allow path was inert, and the card that then went
            // to the phone carried an internal error as its reason instead
            // of "the decider allowed this and the press did not land".
            // Deduplicated, like every other way into the store.
            //
            // `processDialog` runs more than once for one dialog —
            // window-created and focused-window-changed both fire, and the
            // registration sweep adds a third — so two `handle()` tasks
            // exist for the same sheet, each with its own id. While this
            // path was dead they both failed and `escalate`'s dedup
            // collapsed them; now they would both press, and a dialog that
            // survives the first press gets the action twice.
            // Claimed BEFORE the store write. The other way round, losing
            // the claim to a concurrent tap left the request sitting in
            // the store with no `broadcast` and no push behind it — a
            // card that appears only on the next poll, if at all.
            guard claimPress(request.id) else { return }
            guard await store.addDeduplicated(request) else {
                releasePress(request.id)
                return
            }
            // The same claim the human path takes. A bare insert/remove
            // pair would drop someone else's claim: if a tap from the
            // phone claimed this id in the actor hop above, the
            // unconditional `remove` below released it mid-press, and a
            // second tap could press the same control again.
            let result = await executor.execute(.pressButton(requestId: request.id, optionId: optionId))
            releasePress(request.id)
            audit(request: request, decision: decision, result: result)
            // Either way it comes back out: on success there is nothing
            // left to answer, and on failure `escalate` has to be able to
            // add it again — its dedup guard would otherwise see the entry
            // this line just made and suppress the card entirely.
            _ = await store.resolve(id: request.id)
            if result.status == .failed {
                // …unless the dialog is not there any more. `processDialog`
                // fires two or three times for one sheet, each with its
                // own id, so when the first task's press lands and
                // resolves, the second presses a dead element, fails, and
                // used to put a card AND a push notification in front of
                // the person for a dialog they had already answered. The
                // sweep took the card back two seconds later; the push had
                // gone.
                if !DialogRegistry.shared.isLive(id: request.id) { return }
                await escalate(request, note: "Auto-press failed: \(result.reason)")
            } else if !result.landed {
                // Delivered and ignored. `main.swift` keeps the registry
                // entry in this case, and discarding here anyway — which
                // this branch used to do unconditionally — took the card
                // off the phone for a dialog that is still on the Mac,
                // with nothing left to raise it again. Put it back in
                // front of the person instead.
                await escalate(request, note: "Pressed it, and the dialog is still on screen. "
                    + "It may be a macOS prompt that only answers to the Mac itself.")
            } else {
                DialogRegistry.shared.discard(id: request.id)
                // A phone that polled /api/pending inside the press window
                // has this card and nothing would ever take it down.
                await broadcastResolved(id: request.id)
            }

        case .deny:
            // "Left alone" meant: no press, no card, no notification, one
            // audit line nobody reads — and an app still blocked on a
            // sheet you were never told about. `Policy.evaluate` was
            // changed to stop doing exactly this ("silently dropped and
            // never reached your phone"); the model's deny path was not
            // brought along.
            //
            // If the decider named a button, press it. If it did not,
            // this is a decision jev cannot carry out, which makes it
            // yours.
            if let optionId = decision.chosenOptionId,
               request.options.contains(where: { $0.id == optionId }) {
                if let blocked = await refuseToAutoPress(request, optionId: optionId,
                                                         by: decision.source) {
                    await escalate(request, note: blocked)
                    return
                }
                // Deduplicated, for the reason the allow branch spells
                // out: the watcher raises the same sheet two or three
                // times with different ids, and `store.add` keys on the
                // id so it collapses nothing. Both tasks would press.
                // Claimed before the store write, like the allow branch:
                // losing the claim afterwards leaves the request in the
                // store with no broadcast and no push behind it.
                guard claimPress(request.id) else { return }
                guard await store.addDeduplicated(request) else {
                    releasePress(request.id)
                    return
                }
                let result = await executor.execute(.pressButton(requestId: request.id, optionId: optionId))
                releasePress(request.id)
                audit(request: request, decision: decision, result: result)
                _ = await store.resolve(id: request.id)
                if result.status == .failed {
                    // Same guard as the allow branch: do not raise a card
                    // and a push for a dialog that has already gone.
                    if !DialogRegistry.shared.isLive(id: request.id) { return }
                    await escalate(request, note: "Could not decline it for you: \(result.reason)")
                } else if !result.landed {
                    await escalate(request, note: "Declined it, and the dialog is still on screen. "
                        + "It may be a macOS prompt that only answers to the Mac itself.")
                } else {
                    DialogRegistry.shared.discard(id: request.id)
                    await broadcastResolved(id: request.id)
                }
            } else {
                audit(request: request, decision: decision,
                      result: .ok(reason: "Denied by \(decision.source), but no button to press — asking you."))
                await escalate(request, note: decision.reason)
            }

        case .askHuman:
            await escalate(request, note: decision.reason)
        }
    }

    /// Park the request and get it in front of the human.
    private func escalate(_ request: ApprovalRequest, note: String) async {
        guard await store.addDeduplicated(request) else {
            JevLog.write("[jev] duplicate approval suppressed: \(request.title)")
            return
        }
        JevLog.write("[jev] Needs you: \(request.originatingApp.name) — \(request.title) (\(note))")
        await broadcast(event: "approval", request: request)

        // The phone is usually asleep in a pocket when this fires; the open
        // socket reaches nobody. Push is what actually gets your attention.
        await PushStore.shared.notify(
            title: request.originatingApp.name,
            body: request.title,
            url: Tailnet.publicURL(path: "/?approval=\(request.id)"))
    }

    private func broadcast(event: String, request: ApprovalRequest) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(request),
              let json = String(data: data, encoding: .utf8) else { return }
        // Shape must match what the client actually listens for: it switches on
        // message.type and reads message.approval. The previous
        // {"event":…,"request":…} was silently ignored by every client.
        let message = #"{"type":"\#(event)","approval":\#(json)}"#
        for socket in pruneSockets() {
            await socket.send(text: message)
        }
    }

    // MARK: - Routes

    private func registerRoutes(on server: HTTPServer) {
        let store = self.store
        let executor = self.executor
        let policy = self.policy

        server.onPendingRequests {
            await store.getAllPending()
        }

        server.onDecide { [weak self] requestId, optionId, nonce in
            guard let self else { return .failed(reason: "Shutting down") }

            // Actually check the nonce.
            //
            // `Nonce.isValid` existed, was unit-tested, and was called from
            // nowhere — so the self-test reported "replay guard rejects
            // duplicate nonce" while there was no replay guard. A captured
            // decision could be replayed at any time; the bearer token was
            // the only gate on a request that presses buttons.
            switch await self.acceptNonce(nonce) {
            case .fresh:
                break
            case .replayed:
                JevLog.write("[jev] rejected a replayed decision")
                return .failed(reason: "That answer was already used — tap it again")
            case .stale:
                // Distinguish the two. Telling someone their answer was
                // "already used" when the truth is that the card sat there
                // too long sends them looking for a second tap they never
                // made.
                JevLog.write("[jev] rejected a stale decision")
                return .failed(reason: "That answer took too long to arrive — tap it again")
            }

            // Not while jev is already pressing it. An early out, so the
            // permission and command paths below are not walked for a
            // press already in flight; the claim that actually decides
            // it is taken just before the press.
            guard await !self.isPressing(requestId) else {
                return .failed(reason: "Your Mac is already answering that one")
            }

            // Take the card away and touch nothing on the Mac.
            //
            // This is the escape hatch every card needs and dialog cards did
            // not have. It resolves the request and drops the AX handle; it
            // does not press, so dismissing a real dialog leaves that dialog
            // exactly where it was, on the Mac, for you to answer there.
            if optionId == "dismiss" {
                _ = await self.store.resolve(id: requestId)
                DialogRegistry.shared.discard(id: requestId)
                await self.broadcastResolved(id: requestId)
                JevLog.write("[jev] dismissed a card; nothing was pressed")
                return .ok(reason: "Dismissed — nothing was pressed")
            }

            // A Claude Code permission request has a hook holding an open
            // HTTP connection for it. Hand it the answer and stop — there is
            // no command on this Mac to run; Claude Code does the running.
            if await self.resolvePermission(id: requestId, optionId: optionId) {
                _ = await store.resolve(id: requestId)
                await self.broadcastResolved(id: requestId)
                return .ok(reason: "Told Claude Code")
            }

            // A browser task waiting mid-step. Claimed before anything else
            // that could mistake it for a dialog.
            if await self.resolveWebConsent(id: requestId, optionId: optionId) {
                // The task itself takes the card down once it sees the answer.
                return .ok(reason: optionId == "yes" ? "Going ahead" : "Stopped")
            }

            // A report has nothing to answer. Claimed before the fallback
            // below, which would otherwise try to press a button on screen.
            if await self.claimWebReport(id: requestId) {
                _ = await store.resolve(id: requestId)
                await self.broadcastResolved(id: requestId)
                return .ok(reason: "Dismissed")
            }

            // A parked voice command resolves here, not through the AX path.
            if let result = await self.resolveCommandApproval(id: requestId, optionId: optionId) {
                _ = await store.resolve(id: requestId)
                await self.broadcastResolved(id: requestId)
                return result
            }

            guard let request = await store.get(id: requestId) else {
                // Take the card down as well. The Mac has no record of this
                // one, so nothing on the phone can ever answer it — leaving
                // it up means tapping the same dead card forever.
                await self.broadcastResolved(id: requestId)
                return .failed(reason: "Your Mac has no record of that one — it is gone now")
            }
            let command: Command = request.kind == .agentToolPrompt
                ? .answerAgentPrompt(requestId: requestId, optionId: optionId)
                : .pressButton(requestId: requestId, optionId: optionId)
            // The person read the button's name on the card and tapped it,
            // and for a high-risk option answered "Are you sure?" as well.
            // This call went in unflagged, so the executor treated the most
            // deliberate input in the whole system as if jev had thought of
            // it unprompted — and applied the never-auto-press list to it.
            // Claimed, not merely checked. `isPressing` above guarded
            // the AUTO press only — nothing was ever added to the set on
            // this path — so two `/api/decide` calls for one id both
            // reached `ButtonPresser`, pressing the same live control
            // twice. Harmless for "Allow"; not for "Send", "Add" or
            // "Purchase".
            //
            // It matters more now than it did: a press that does not
            // land deliberately leaves the card up and tells the person
            // it may not have worked, so tapping again is the obvious
            // next move — and on an app that was merely slow, the
            // control is still there to be pressed.
            guard await self.claimPress(requestId) else {
                return .failed(reason: "Your Mac is already answering that one")
            }
            let result = await executor.execute(command, humanApproved: true, answeredCard: true)
            await self.releasePress(requestId)
            if result.status == .ok, result.landed {
                _ = await store.resolve(id: requestId)
                await self.broadcastResolved(id: requestId)
                return result
            }
            // Pressed, ignored, dialog still up. Resolving here — which
            // is what `.ok` alone used to do — withdrew the card one
            // frame after `main.swift` had deliberately kept the handle
            // to press again, and nothing raises a card for a window
            // that is already being watched. The prompt was then stuck
            // on the Mac with no remote way to answer it at all, which
            // is worse than never having sent the card.
            if result.status == .ok {
                return result
            }

            // The press failed. If the dialog it belongs to is no longer
            // there, the card can never be answered — so take it away rather
            // than leave it on the phone forever.
            //
            // This is what stranded two “[AXSheet]” cards that no amount of
            // tapping Allow could clear: jev knew the dialog had gone (it
            // said so in the reason) and kept the card up anyway.
            if request.kind == .appDialog || request.kind == .tccConsent,
               !DialogRegistry.shared.isLive(id: requestId) {
                _ = await store.resolve(id: requestId)
                DialogRegistry.shared.discard(id: requestId)
                await self.broadcastResolved(id: requestId)
                JevLog.write("[jev] withdrew “\(request.title)” — its dialog is gone")
                return .failed(reason: "That dialog closed on the Mac, so this card is gone too.")
            }
            return result
        }

        server.onScreenshot { _ in
            await ScreenCapturer.shared.captureDisplay(maxDimension: 1400, quality: 0.7)
        }

        // The phone needs the display's real size to turn a tap on a scaled
        // JPEG back into a screen coordinate.
        server.onSwipe { nx, ny, dx, dy in
            let frame = Pointer.displayBounds()
            let result: ExecutionResult
            if let at = Pointer.screenPoint(nx: nx, ny: ny, in: frame) {
                result = Pointer.scroll(dx: dx * frame.width, dy: dy * frame.height, at: at)
            } else {
                result = .failed(reason: "That is not a place on the screen")
            }
            let payload: [String: Any] = ["ok": result.status == .ok, "reason": result.reason]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
        }

        // Where the pointer is, normalised against the display, so the phone
        // can draw it at whatever scale it is showing the screen.
        server.onCursor {
            let frame = Pointer.displayBounds()
            guard frame.width > 0, frame.height > 0 else { return "null" }
            let point = Pointer.location()
            let payload: [String: Any] = [
                "x": point.x / frame.width,
                "y": point.y / frame.height,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return String(data: data, encoding: .utf8) ?? "null"
        }


        // A tap on the screen view. Coordinates arrive normalised 0..1 so the
        // phone never has to know the display size or the JPEG scale.
        server.onTap { nx, ny, kind in
            let frame = Pointer.displayBounds()
            guard let at = Pointer.screenPoint(nx: nx, ny: ny, in: frame) else {
                return #"{"ok":false,"reason":"That is not a place on the screen"}"#
            }
            let result = Pointer.perform(kind, at: at)
            let payload: [String: Any] = ["ok": result.status == .ok, "reason": result.reason]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
        }

        server.onCommand { [weak self] text, ordinalsAreTheirs in
            guard let self else { return .failed(reason: "Shutting down") }
            let started = Date()
            // The world, read once. Every stage below interprets the sentence
            // against this same reading, so none of them re-reads the screen
            // mid-sentence and none of them has to be handed an empty scope to
            // avoid blocking. See Scope.
            // What was actually spoken, kept whole. `text` below is the
            // sentence an address has been taken off the front of, and the
            // journal's one job is to say what was said.
            let said = text
            let (scope, text) = await Self.addressed(Scope.current(), said: text)
            let frontApp = scope.app.isEmpty ? "unknown" : scope.app
            // One line per command saying what the world looked like. Without
            // it a stale-scope miss and a precedence miss are the same log.
            JevLog.write("[jev] scope: app=\(frontApp)"
                + (scope.fromCursor && scope.activeApp != scope.app && !scope.activeApp.isEmpty
                    ? " (macOS says \(scope.activeApp))" : "")
                + " monitor=\(scope.monitorApps.prefix(4).joined(separator: "|"))"
                + (scope.context.host.map { " page=\($0)" } ?? "")
                + " controls=\(scope.visibleLabels.count)"
                + (scope.underPointer.map { " pointer=“\($0.prefix(30))”" } ?? "")
                + " running=\(scope.runningApps.count) installed=\(scope.installedApps.count)"
                + " wm=\(scope.workspaceManager.rawValue)"
                + (scope.workspace.map { "@\($0)" } ?? ""))
            // Every route below ends here, so there is exactly one line per
            // command and it always says which path claimed it.
            func journal(_ route: String, _ command: String,
                         _ result: ExecutionResult,
                         kind: Command? = nil,
                         /// The whole phrase, when what arrived was only part
                         /// of one. On the finishing route `text` is the bare
                         /// answer — "hunter2" — and the redaction's
                         /// keep-the-first-word rule would then keep the
                         /// secret itself.
                         heard: String? = nil,
                         /// Nothing understood this. See CommandJournal.
                         unparsed: Bool = false,
                         verified: String? = nil,
                         judged: CommandJournal.Judgement? = nil) -> ExecutionResult {
                CommandJournal.record(heard: heard ?? said, route: route, command: command,
                                      kind: kind, result: result, started: started,
                                      app: frontApp, verified: verified, unparsed: unparsed,
                                      judged: judged)
                return result
            }

            // Who wins between a button on screen and a built-in shortcut
            // depends on whether you said a verb.
            //
            //   "click save"  → the Save button. You pointed at something.
            //   "save"        → ⌘S. The shortcut, as it has always been.
            //
            // An earlier pass let the screen win outright, and that quietly
            // stole a lot of vocabulary: "save", "back", "find", "copy" and
            // "play" are all ordinary button labels, so on the wrong page
            // they stopped doing what they had always done. The bug that
            // started this was "click skip" — the verb was there all along,
            // and it is the only signal that a control was meant.
            // Finishing a command you already started.
            //
            // "switch workspace" is a real command with one piece missing.
            // Saying it used to end in "did not understand", so the whole
            // sentence had to be repeated just to add "2". If the last thing
            // asked for a value and this is short enough to be one, put them
            // together instead.
            // A number belongs to the badges, and to nothing else.
            //
            // FIRST, before any channel. Placing it after
            // `takePendingArgument` left that one channel able to
            // consume it — "set volume to" pending, badges up, "two"
            // set the volume AND the phone tapped badge 2.
            //
            // The test is what the PHONE claims, not what an ordinal
            // means to the Mac. Those were two different grammars and
            // they disagreed both ways: the Mac claimed "second" and
            // the phone did not, so the word vanished and was reported
            // as done; the phone claimed "press 2" and the Mac did
            // not, so the digit was typed into the app AND the badge
            // was pressed.
            // …unless jev asked a question more recently than the
            // badges went up.
            //
            // Deferring unconditionally made the refusal's own advice
            // unfollowable whenever the phone's websocket was down: the
            // Mac's "take the badges away" message is fire-and-forget,
            // so the phone kept them up, kept sending `?badges=1`, and
            // the answer was handed to a badge that means something
            // else. An armed choice is a question this end is waiting
            // on, and it wins.
            if ordinalsAreTheirs, await self.hasAnswerableChoice(for: text) {
                // fall through: the Mac takes it
            } else if ordinalsAreTheirs, JevRuntime.badgeNumber(in: text) != nil {
                return journal("badge/deferred", "the phone owns that number",
                               .ok(reason: "That number is for the badge on your screen"),
                               heard: text)
            }

            if let pending = await self.takePendingArgument(for: text, in: scope) {
                let phrase = pending + " " + text
                let parsed = VoiceCommand.parse(phrase, in: scope.context)
                // On this route the answer is ALWAYS a value the person
                // supplied — that is what the route is for. So it is never
                // written down, whatever command it turns into.
                //
                // Three narrower rules were each wrong here. Keying on the
                // verb missed it ("hunter2" has none). Keying on the
                // command missed `.rightClickControl`, which carries a
                // label rather than "free text". Keying on the parse
                // missed the case where nothing parsed at all.
                JevLog.write("[jev] finishing “\(pending)” with <not recorded> (\(JevLog.shape(text)))")
                if let parsed {
                    // `unparsed: true` unconditionally, because on THIS
                    // route the answer is always a value the person
                    // supplied — whatever command it turns into. "right
                    // click on" + "hunter2" builds a `.rightClickControl`,
                    // which carries no free text as far as the command tree
                    // is concerned, so the answer went to disk intact.
                    return journal("finishing", parsed.description,
                                   await self.dispatch(parsed, spokenAs: phrase,
                                                       spokenIsPrivate: true, in: scope),
                                   kind: parsed.command, heard: phrase, unparsed: true)
                }
                // The phone still gets the whole sentence; the disk gets none
                // of it. Nothing parsed, so there is no verb worth keeping.
                return journal("finishing", pending,
                               .failed(reason: "“\(text)” does not work for \(pending)"),
                               heard: phrase, unparsed: true)
            }

            // "number two", answering the question the last refusal asked.
            //
            // Before the phrasebook and before the model, because a bare
            // ordinal parses as nothing and would otherwise reach the
            // decider, which cannot know what was on the screen when the
            // question was asked. It runs the ordinary `.clickControl`
            // route, so the label is still journalled, still rated, and
            // still gated by policy — the number only says WHICH of the
            // equally-named ones.
            if let choice = await self.takePendingChoice(for: text) {
                let described = "\(choice.rightClick ? "Right-click" : "Click") "
                    + "“\(choice.label)” (\(choice.nth) of \(choice.count))"
                // The label can BE the private value — "right click on"
                // + a spoken password builds `.rightClickControl(label:
                // <value>)`. The route that armed this redacted it; the
                // answer has to as well, or it reaches jev.log and
                // commands.jsonl in full.
                JevLog.write("[jev] picking \(choice.nth) of \(choice.count) controls"
                    + (choice.saidIsPrivate ? "" : " called “\(choice.label)”"))
                // The same verb that asked the question.
                let command: Command = choice.rightClick
                    ? .rightClickControl(label: choice.label, nth: choice.nth,
                                         outOf: choice.count, inWindow: choice.window)
                    : .clickControl(label: choice.label, nth: choice.nth,
                                    outOf: choice.count, inWindow: choice.window)
                // `spokenAs` keeps the sentence that named the control,
                // not the bare "number two" — the approval card quotes
                // it, and "You said “number two”" tells someone
                // approving a destructive click nothing at all.
                // The privacy of the original sentence travels with
                // it. The finishing route marks a spoken VALUE private
                // so it never reaches the decider; an ambiguity in the
                // middle used to drop that flag and post it anyway.
                return journal("screen/nth", described, await self.dispatch(
                    VoiceCommand.Parsed(command: command, description: described),
                    spokenAs: "\(choice.said) → \(text)",
                    spokenIsPrivate: choice.saidIsPrivate, in: scope),
                    kind: command, heard: text, unparsed: choice.saidIsPrivate)
            }

            // Every stage proposes; one comparison chooses, cursor outward.
            // See Candidates. The vocabulary keeps its effect check below.
            let pressed = JevIntent.startsWithPressVerb(text)
            let onScreen = await self.controlMatching(text, in: scope)
            let chosen = Candidates.choose(text: text, scope: scope, pressed: pressed,
                                           onScreen: onScreen,
                                           parsed: VoiceCommand.parse(text, in: scope.context))
            if let chosen, chosen.level != .global {
                JevLog.write("[jev] \(chosen.route): \(chosen.parsed.description)")
                return journal(chosen.route, chosen.parsed.description,
                               await self.dispatch(chosen.parsed, spokenAs: text, in: scope),
                               kind: chosen.parsed.command)
            }

            if let chosen, chosen.level == .global, case let parsed = chosen.parsed {
                // Take a fingerprint of the screen either side, for the
                // commands that cannot report their own effect. A keystroke
                // says "delivered", never "it worked".
                let checking = EffectCheck.worthChecking(parsed.command)
                // Started, not awaited. The header of EffectCheck promises
            // the "before" frame is taken WHILE the command runs and
            // that the check never slows anything — and this awaited a
            // full ScreenCaptureKit frame first, so every keystroke,
            // scroll and click paid for it before anything happened.
            // Stamped, because a race that usually loses is a lie.
            //
            // `sample()` is an XPC round trip to the window server plus a
            // capture — tens to hundreds of milliseconds — while a
            // keystroke returns in microseconds. So "concurrent" means
            // the before-frame is normally taken AFTER the effect has
            // painted, and the comparison then says "no-change" for a
            // command that worked: a false negative on exactly the
            // commands this check exists for. The timestamp lets the
            // verdict say "could not tell" instead of saying the wrong
            // thing confidently.
            let beforeTask: Task<(EffectCheck.Fingerprint?, Date), Never>? =
                checking ? Task { (await EffectCheck.sample(), Date()) } : nil
                let result = await self.dispatch(parsed, spokenAs: text, in: scope)
                let dispatchEnded = Date()

                guard checking else {
                    return journal("vocabulary", parsed.description, result, kind: parsed.command)
                }
                // Finish the check AFTER answering. Waiting for the screen to
                // settle turned a 150 ms command into an 850 ms one, and the
                // only thing that wait buys is a word in a log — nobody is
                // watching the journal in real time, and the phone is.
                let described = parsed.description
                let kind = parsed.command
                let heardNow = text
                let app = frontApp
                let took = Int(Date().timeIntervalSince(started) * 1000)
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: .milliseconds(350))
                    // Collected here, where waiting costs nothing —
                    // this task already runs after the answer has gone
                    // to the phone. And only trusted if it landed while
                    // the command was still running; otherwise there is
                    // no "before" and the honest answer is no answer.
                    let captured = await beforeTask?.value
                    let inTime = (captured?.1).map { $0 <= dispatchEnded } ?? false
                    // And SAY "could not tell", rather than leaving the
                    // field absent. A nil `verified` encodes to no key at
                    // all, which is byte-identical to a command that was
                    // never checked — so the one distinction this whole
                    // timestamp exists to draw was invisible in the file.
                    // Also skips the second capture when there is no
                    // first one to compare against.
                    // Always a word, never an absent key. A nil
                    // `verified` encodes to nothing at all, which is
                    // byte-identical to a command that was never
                    // checked — and that is the one distinction this
                    // timestamp exists to draw. The after-capture can
                    // fail too, so it gets the same treatment.
                    let verdict: String?
                    if inTime, let before = captured?.0 {
                        verdict = EffectCheck.verdict(before: before, after: await EffectCheck.sample())
                            ?? EffectCheck.missing
                    } else {
                        verdict = EffectCheck.missing
                    }
                    CommandJournal.record(heard: heardNow, route: "vocabulary",
                                          command: described, kind: kind,
                                          result: result,
                                          started: started, app: app,
                                          verified: verdict, tookMs: took)
                }
                return result
            }

            // A command that is right but incomplete: ask for the rest
            // rather than throwing the sentence away.
            if let phrase = Phrasebook.awaitingArgument(text, in: scope.context) {
                await self.rememberPendingArgument(phrase)
                return journal("asking", phrase, .ok(reason: Self.askFor(phrase)))
            }

            // No verb and no shortcut: a bare word that happens to name a
            // button on screen is almost certainly that button.
            // The window level, bubbled past global: a bare word that names a
            // button and nothing else claimed. Same answer as above, not a
            // second look.
            if !pressed, let onScreen {
                JevLog.write("[jev] on screen: “\(onScreen)” — nothing else claims that word")
                return journal("screen/bare", "clickControl(\(onScreen))", await self.dispatch(
                    VoiceCommand.Parsed(command: .clickControl(label: onScreen),
                                        description: "Click “\(onScreen)”"),
                    spokenAs: text, in: scope),
                    kind: .clickControl(label: onScreen))
            }

            if let prefix = policy.allowedCommandPrefixes.first(where: { text.hasPrefix($0) }) {
                return journal("shell", "runCommand(\(prefix))",
                               await executor.execute(.runCommand(allowlistedPrefix: prefix, fullCommand: text)))
            }

            // The literal parser only knows open/quit. Anything else goes to
            // Jev, which picks from things that actually exist on this Mac —
            // installed apps and the controls really on screen — so it can only
            // ever name something actionable.
            guard let apiKey = JevAPI.loadAPIKey() else {
                // Journalled like every other terminal path. Without this,
                // an unparseable command on a Mac with no key produced no
                // record at all, and "exactly one line per command" was
                // quietly untrue.
                return journal("no-key", "-",
                    .failed(reason: "Did not understand “\(text)”, and no Jev key is configured to interpret it"),
                    unparsed: true)
            }

            switch await JevIntent.resolve(transcript: text,
                                           alternatives: await self.readings(for: text),
                                           frontmostApp: scope.app.isEmpty ? nil : scope.app,
                                           controls: scope.visibleLabels,
                                           context: scope.context,
                                           runningApps: scope.runningApps,
                                           workspaces: scope.workspaces,
                                           apiKey: apiKey) {
            case .failure(let error):
                JevLog.write("[jev] intent: \(error.description)")

                // Fail closed. This used to hand the transcript to JevPlan,
                // which guessed a two-to-four step Phrasebook sequence out of
                // words nobody had mapped — a plan invented from a miss. The
                // observe/act loop is the planner now; a command we cannot
                // resolve is a command we do not run.
                return journal("model/failed", "-",
                               .failed(reason: "Did not understand “\(text)” — \(error.description)"),
                               unparsed: true)

            case .success(let resolution):
                JevLog.write("[jev] intent: \(resolution.description) confidence=\(String(format: "%.2f", resolution.confidence)) routine=\(String(format: "%.2f", resolution.verdict.routine)) destructive=\(String(format: "%.2f", resolution.verdict.destructive))")

                // A guess is not a mandate. Anything Jev is unsure of, or calls
                // hard to undo, goes to you rather than straight to the machine.
                guard resolution.confidence >= 0.55, !resolution.verdict.looksDestructive else {
                    let parsed = VoiceCommand.Parsed(command: resolution.command, description: resolution.description)
                    // "Asked you" is not "did it".
                    //
                    // Journalling this as ok made a command that never ran
                    // look successful. But raising the card DID succeed, so
                    // the phone must still be told ok — only the journal
                    // needs to say the command is merely pending. The route
                    // name carries that, and `verified` says it outright.
                    let asked = await self.requestApproval(
                        for: parsed, spokenAs: text,
                        key: scope.policyKey(for: parsed.command), aim: scope.aim,
                        // Two different doubts reach this guard, and the card
                        // should say which one it is.
                        reason: resolution.verdict.looksDestructive
                            ? .hardToUndo : .halfHeard(confidence: resolution.confidence))
                    CommandJournal.record(heard: text, route: "model/asked",
                                          command: parsed.description, kind: parsed.command,
                                          result: asked, started: started,
                                          app: frontApp, verified: "pending-your-answer",
                                          judged: CommandJournal.Judgement(
                                            confidence: resolution.confidence,
                                            routine: resolution.verdict.routine,
                                            destructive: resolution.verdict.destructive,
                                            // The whole point of the line: a
                                            // card at 0.54 and a card at 0.98
                                            // are different problems.
                                            asked: resolution.verdict.looksDestructive
                                                ? "hard-to-undo" : "half-heard"))
                    return asked
                }

                let parsed = VoiceCommand.Parsed(command: resolution.command, description: resolution.description)
                return journal("model", parsed.description,
                               await self.dispatch(parsed, spokenAs: text, verdict: resolution.verdict,
                                                   in: scope),
                               kind: parsed.command,
                               judged: CommandJournal.Judgement(
                                confidence: resolution.confidence,
                                routine: resolution.verdict.routine,
                                destructive: resolution.verdict.destructive))
            }
        }

        // Voice: the phone uploads recorded audio, the Mac transcribes it with
        // Apple Speech (no API key needed) and hands back the text. This route
        // was never registered before, so every recording came back
        // "Handler not configured".
        server.onVoiceUpload { audio in
            let ext = Transcription.fileExtension(forFirstBytesOf: audio)
            let head = audio.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
            JevLog.write("[jev] voice: \(audio.count) bytes, sniffed .\(ext), head=\(head)")
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("jev-voice-\(UUID().uuidString).\(ext)")
            do {
                try audio.write(to: tmp)
            } catch {
                JevLog.write("[jev] voice: could not write temp audio: \(error)")
                return nil
            }
            defer { try? FileManager.default.removeItem(at: tmp) }

            // Safari hands us WebM/Opus whatever the client requests, and
            // Apple Speech cannot open it. Convert first when needed.
            var audioURL = tmp
            var transcoded: URL?
            if !Transcription.isNativelyReadable(ext) {
                guard let wav = Transcription.transcodeToWav(tmp) else {
                    JevLog.write("[jev] voice: cannot transcode .\(ext) and Apple Speech cannot read it")
                    return nil
                }
                JevLog.write("[jev] voice: transcoded .\(ext) to wav")
                audioURL = wav
                transcoded = wav
            }
            defer { if let transcoded { try? FileManager.default.removeItem(at: transcoded) } }

            // Gemini when a key is configured, Apple otherwise and whenever
            // Gemini cannot answer. Opt-in: with no key this is exactly the
            // recogniser jev has always used.
            let transcriber = FallbackTranscriber(
                preferred: GeminiTranscriber(),
                fallback: SpeechRecognizer(),
                preferredIsConfigured: { GeminiTranscriber.isConfigured })
            let result = await transcriber.transcribe(audioURL: audioURL)
            switch result {
            case .success(let heard):
                // Shape, not words. Nothing has interpreted this yet, so
                // there is no way to know whether it is "next tab" or a
                // passphrase — and the one utterance most likely to be a
                // secret is exactly the one nothing will understand. What
                // jev DID understand gets logged further down, once it
                // knows, and the journal carries the rest.
                JevLog.write("[jev] voice: heard \(JevLog.shape(heard.best))"
                    + (heard.alternatives.isEmpty ? "" : ", \(heard.alternatives.count) other readings"))
                // What is on screen decides which reading is real. A spoken
                // "click skip" was being rewritten to "skip" and firing the
                // media key for next track, because nothing at this stage
                // knew a Skip button was sitting right there.
                let chosen = await SpeechRepair.choose(
                    heard,
                    controls: await CommandExecutor.cua.visibleLabels(),
                    apiKey: JevAPI.loadAPIKey())
                // Kept for the command handler that runs next in this same
                // request: if nothing parses, Jev should see every reading,
                // not just the one that failed.
                await self.rememberReadings(for: chosen, all: [heard.best] + heard.alternatives)
                // When nothing understood any reading, record what was on
                // offer. Without this a mis-hearing is undiagnosable: the log
                // said "heard 4 words, 4 other readings" and never whether
                // the right words were among them — which is the only
                // question worth asking. Written through the same filter as
                // everything else, so a reading that carries a value is
                // withheld rather than printed.
                if VoiceCommand.parse(chosen) == nil {
                    let offered = ([heard.best] + heard.alternatives)
                        .map { JevLog.safe($0) }
                        .joined(separator: " | ")
                    JevLog.write("[jev] voice: nothing parsed; readings were: \(offered)")
                }
                return chosen
            case .failure(let error):
                JevLog.write("[jev] voice: transcription failed: \(error)")
                return nil
            }
        }

        // "modes" over the command channel so a wrong "never" is recoverable
        // from the phone instead of needing a file edit.
        // Read the whole policy: the default plus every explicit override,
        // with a readable name for each so the phone is not showing bundle ids.
        // Typed text from the phone. Deliberately separate from voice: a
        // password must never be spoken aloud, transcribed, sent to a model,
        // or written to the log. Secret text is redacted at every step.
        server.onType { text, field, secret in
            let started = Date()
            let command: Command = field.map { .fillField(label: $0, text: text) }
                ?? .typeText(text: text)
            // Typed from the phone: no scope was resolved, so it goes where
            // focus is, which is what someone typing expects — no aim.
            let result = await executor.execute(command, humanApproved: true)
            // If the typed value is anywhere in the reason, the reason is
            // not ours and goes back through the ordinary redaction.
            //
            // Substituting it out was worse: the replacement is global
            // and unanchored, so typing "Chrome" turned "Typed into
            // Chrome" into "Typed into <not recorded>" and typing "Email"
            // mangled "Filled “Email address”". Deciding rather than
            // editing cannot corrupt anything.
            //
            // An exact substring test is not enough: a driver that
            // echoes the value TRANSFORMED — trimmed, case-folded,
            // truncated to fit a message, percent-encoded — does not
            // contain it verbatim, the reason is declared jev's own,
            // redaction is skipped, and the typed value goes to
            // `commands.jsonl`, which `/api/journal` serves. So the
            // test looks for the shapes an echo actually takes, and
            // when in doubt the reason is treated as not ours, which
            // costs nothing but a redacted line.
            let reasonIsJevs = text.isEmpty || !Self.reasonEchoes(text, in: result.reason)
            // Never the exact length, secret flag or not. That count was
            // removed from the spoken path on the grounds that the precise
            // length of a passphrase is a real fact about it — and this is
            // the path people use *because* it is the safe one. The flag
            // cannot be trusted to mark it either: Chrome reports an
            // unlabelled <input type="password"> as a plain text field, so
            // `looksSecret` says false for exactly the boxes that matter.
            JevLog.write("[jev] typed \(JevLog.shape(text))"
                + (field.map { " into \($0)" } ?? "") + " -> \(result.status.rawValue)")
            // And a journal line, which this route never wrote — the
            // contract says exactly one per command, and typed text was
            // the one command that produced none.
            CommandJournal.record(
                heard: secret ? "<secret>" : "typed",
                route: "type", command: field == nil ? "typeText" : "fillField",
                kind: command, result: result, started: started,
                app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown",
                // The sentence explaining a failure survives intact —
                // but only after making sure it is jev's sentence. The
                // last `catch` in `fill` and `type` returns the DRIVER's
                // error text, and the value we sent is in the request
                // that produced it; a validator that echoes the offending
                // field would put the password straight through a flag
                // that disables redaction.
                reasonIsOurs: reasonIsJevs)
            let payload: [String: Any] = ["ok": result.status == .ok, "reason": result.reason]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
        }

        server.onPolicy {
            let store = AppPolicyStore.shared
            let friendly: [String: String] = [
                "system.gesture": "Scrolling",
                "system.workspace": "Workspace switching",
                "system.pointer": "Clicking on screen",
                "system.keyboard": "Typing and shortcuts",
            ]
            let entries = store.all.map { id, mode -> [String: Any] in
                let name = friendly[id]
                    ?? AppCatalog.shared.all.first { $0.bundleIdentifier == id }?.name
                    ?? id
                return ["id": id, "name": name, "mode": mode.rawValue]
            }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

            var payload: [String: Any] = [
                "global": store.globalMode.rawValue,
                "globalOptions": GlobalMode.allCases.map { ["id": $0.rawValue, "label": $0.explanation] },
                "entries": entries,
            ]
            // A notification path that is refusing every send is the
            // product not working, and the phone is the one place that
            // cannot tell. It goes out with the settings the person
            // opens when they wonder why nothing is arriving.
            if let failure = PushStore.shared.lastFailure {
                payload["pushError"] = failure
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        // Claude Code's PermissionRequest hook.
        //
        // hooks/jev-permission-hook.sh has been posting to this route since
        // the repo was created and nothing was listening: the route did not
        // exist, so every request timed out and fell back to the interactive
        // prompt on the Mac. That is the whole Claude-Code-from-your-pocket
        // story, and it has never once worked.
        //
        // Order is policy, then the model, then you. Policy first so nothing
        // the allowlist already refuses is ever sent to a model, and no model
        // answer can widen what policy permits.
        server.onPermission { [weak self] body in
            guard let self else { return #"{"allow":false,"reason":"jev is shutting down"}"# }
            return await self.decidePermission(body)
        }

        server.onSetPolicy { body in
            guard let data = body.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return #"{"ok":false,"error":"bad request"}"#
            }
            let store = AppPolicyStore.shared

            if let global = payload["global"] as? String, let mode = GlobalMode(rawValue: global) {
                store.setGlobal(mode)
            }
            if let id = payload["id"] as? String {
                if let raw = payload["mode"] as? String, let mode = AppMode(rawValue: raw) {
                    store.set(mode, for: id)
                } else {
                    // No mode means "stop having an opinion about this app".
                    store.forget(id)
                }
            }
            if payload["reset"] as? Bool == true {
                store.reset()
            }
            return #"{"ok":true}"#
        }

        // Web Push: the key the browser needs to subscribe, and the resulting
        // subscription. Without these the approval only exists inside an app
        // you already have open — which is the case the whole product is for.
        server.onVapidKey {
            guard let key = PushStore.shared.publicKey else {
                return #"{"error":"push unavailable"}"#
            }
            return #"{"vapidKey":"\#(key)"}"#
        }

        server.onSubscribe { body in
            guard let data = body.data(using: .utf8),
                  let subscription = try? JSONDecoder().decode(PushSubscription.self, from: data),
                  subscription.endpoint.hasPrefix("https://") else {
                return #"{"ok":false,"error":"malformed subscription"}"#
            }
            PushStore.shared.add(subscription)
            return #"{"ok":true}"#
        }

        // Numbers over the picture, for when names cannot tell two things
        // apart — four buttons all called "Alex" in Chrome's profile picker.
        server.onControls {
            let rows: [(number: Int, label: String, x: Double, y: Double, w: Double, h: Double)]
            do {
                rows = try await CommandExecutor.cua.numberedControls()
            } catch {
                // Say why, in the one vocabulary. Returning [] made a broken
                // driver look like an empty screen, which is the least useful
                // thing it could say.
                JevLog.write("[jev] numbers: \(error)")
                let payload: [String: Any] = ["error": "\(error)"]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            let payload = rows.map { row -> [String: Any] in
                ["n": row.number, "label": row.label,
                 "x": row.x, "y": row.y, "w": row.w, "h": row.h]
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        // Every command, with how it routed and how long it took.
        server.onJournal {
            let entries = CommandJournal.recent(80)
            let data = (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        server.onWebSocketConnect { [weak self] session in
            guard let self else { return }
            Task { await self.addSocket(session) }
        }
    }

    // ── Finishing an unfinished command ─────────────────────────────────

    /// The phrase still waiting for its missing value, and when it asked.
    private var pendingArgument: (phrase: String, asked: Date)? {
        get { _pendingArgument }
        set { _pendingArgument = newValue }
    }

    /// A click that found several equally-good controls, and the label
    /// it was looking for.
    ///
    /// The refusal tells the person there are three and asks which; this
    /// is what makes the answer mean something thirty seconds later.
    /// Without it, "the second one" is a sentence with no subject and
    /// goes to the model, which cannot know what was on screen.
    /// An instance property, not a `nonisolated(unsafe) static`.
    ///
    /// The first version copied the shape of `_pendingArgument` above —
    /// except that one is an ordinary actor-isolated property, so the
    /// copy was of something that was not there. A static is
    /// process-global and gives up the compiler check that would catch
    /// a future `nonisolated` helper touching it.
    private var _pendingChoice: (label: String, count: Int, said: String, rightClick: Bool,
                                 saidIsPrivate: Bool, window: Int?, asked: Date)?
    private var pendingChoice: (label: String, count: Int, said: String, rightClick: Bool,
                                saidIsPrivate: Bool, window: Int?, asked: Date)? {
        get { _pendingChoice }
        set { _pendingChoice = newValue }
    }

    /// Did this utterance pick one of the controls we just asked about?
    ///
    /// Returns the label and the ordinal, or nil if this was not an
    /// answer. Deliberately narrow: an ordinal and nothing else, inside
    /// the same half-minute the question was asked, and never a phrase
    /// that stands on its own as a command.
    /// Is there a live question here that this utterance answers?
    ///
    /// Read-only — it does not consume the choice, because the caller
    /// may still hand the word to the badges.
    func hasAnswerableChoice(for text: String) -> Bool {
        guard let pending = pendingChoice,
              Date().timeIntervalSince(pending.asked) < 30,
              let nth = Self.ordinal(in: text) else { return false }
        return nth >= 1 && nth <= pending.count
    }

    func takePendingChoice(for text: String)
        -> (label: String, nth: Int, count: Int, said: String,
            rightClick: Bool, saidIsPrivate: Bool, window: Int?)? {
        guard let pending = pendingChoice else { return nil }
        guard Date().timeIntervalSince(pending.asked) < 30 else {
            pendingChoice = nil
            return nil
        }
        guard let nth = Self.ordinal(in: text), nth >= 1, nth <= pending.count else {
            // Not an answer, so the question is over. Left armed, a
            // stray "two" spoken in the room up to thirty seconds later
            // would click something — and hands-free listens
            // continuously, across launches.
            pendingChoice = nil
            return nil
        }
        pendingChoice = nil
        return (pending.label, nth, pending.count, pending.said,
                pending.rightClick, pending.saidIsPrivate, pending.window)
    }

    /// "two", "number 2", "the second one" — and nothing else.
    ///
    /// Anything longer is a new command. This is the same reasoning as
    /// `takePendingArgument`: a whole sentence is a person moving on.
    /// Would the PHONE read this as a badge number?
    ///
    /// A deliberate mirror of `pressNumber` in `web/app.js`, and a
    /// different question from `ordinal`. `ordinal` answers "is this an
    /// answer to the question jev asked?", which excludes "press 2"
    /// because that is a keystroke. This answers "will the phone act on
    /// this?", which includes it — the phone strips exactly these
    /// verbs.
    ///
    /// They were the same predicate once and disagreed in both
    /// directions: the Mac swallowed "second" (which the phone ignores)
    /// and reported it as done, while "press 2" passed the Mac's test,
    /// typed a digit into the app, AND pressed the badge.
    ///
    /// Kept in step by `SelfTest.checkBadgeNumber`, which carries the
    /// same table as the JavaScript.
    static func badgeNumber(in text: String) -> Int? {
        var said = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
        for verb in ["click", "press", "tap", "pick", "choose", "select", "number", "option"]
        where said.hasPrefix(verb + " ") {
            said = String(said.dropFirst(verb.count + 1))
            break
        }
        if said.hasPrefix("number ") { said = String(said.dropFirst(7)) }
        said = said.trimmingCharacters(in: .whitespaces)
        if let digits = Int(said), digits > 0 { return digits }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                     "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        return words[said]
    }

    static func ordinal(in text: String) -> Int? {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        let words = cleaned.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        // "please" and "thanks" are how people actually talk, and "2nd"
        // is what a speech recogniser routinely emits for "second".
        // "press", "tap", "click" and "option" are NOT ignorable.
        //
        // They are how you say a keystroke: "press 2" types the digit,
        // "press option 1" is ⌥1. Treating them as filler meant that
        // for thirty seconds after any ambiguity those utterances
        // clicked a candidate instead — and ordinals are checked before
        // the phrasebook and before the model, so nothing downstream
        // could recover them.
        let ignorable: Set<String> = ["number", "the", "one", "please", "thanks",
                                      "thank", "you"]
        // …and a phrase that stands on its own as a command is never an
        // answer. Same rule `takePendingArgument` states and this
        // function's own docstring claimed without implementing.
        if Phrasebook.claimsExactly(cleaned, in: Phrasebook.neutral) { return nil }
        let meaningful = words.filter { !ignorable.contains($0) }
        // "the one" and "number one" both mean the first; with every
        // ignorable word gone, "one" has been eaten, so an utterance that
        // is nothing BUT ignorable words means the first only when it
        // actually said "one".
        guard let token = meaningful.last ?? (words.contains("one") ? "one" : nil) else { return nil }
        guard meaningful.count <= 1 else { return nil }
        if let digits = Int(token) { return digits }
        // "2nd", "3rd", "11th"
        if token.count >= 3, let suffix = ["st", "nd", "rd", "th"].first(where: token.hasSuffix),
           let digits = Int(token.dropLast(suffix.count)) {
            return digits
        }
        let spelled = ["first": 1, "one": 1, "second": 2, "two": 2, "third": 3, "three": 3,
                       "fourth": 4, "four": 4, "fifth": 5, "five": 5, "sixth": 6, "six": 6,
                       "seventh": 7, "seven": 7, "eighth": 8, "eight": 8,
                       "ninth": 9, "nine": 9, "tenth": 10, "ten": 10]
        return spelled[token]
    }

    private func rememberPendingArgument(_ phrase: String) {
        _pendingArgument = (phrase, Date())
    }

    /// The waiting phrase, if this utterance could be the value it wants.
    ///
    /// Short and recent, both on purpose. A minute later you have moved on,
    /// and a whole sentence is a new command rather than an answer — only
    /// something the length of "2" or "the design one" is a missing piece.
    private func takePendingArgument(for text: String, in scope: Scope) -> String? {
        guard let pending = _pendingArgument else { return nil }
        // A newer question outranks an older one. Both channels are
        // checked in a fixed order, so an unanswered "what level?" from
        // earlier used to swallow the "number two" that answers "which
        // Follow?" — and consume itself doing it, so the first attempt
        // was lost with a message about volume.
        if let choice = _pendingChoice, choice.asked > pending.asked,
           Date().timeIntervalSince(choice.asked) < 30,
           let nth = Self.ordinal(in: text), nth >= 1, nth <= choice.count {
            // In range, so the choice channel really will take it.
            // Without the range check both channels declined — this one
            // yielded because "50" is an ordinal, the other rejected it
            // as out of range AND disarmed — and the utterance was lost
            // with the pending question consumed.
            return nil
        }
        guard Date().timeIntervalSince(pending.asked) < 30 else {
            _pendingArgument = nil
            return nil
        }
        let words = text.split(separator: " ").count
        guard words <= 4 else { return nil }
        // Anything that stands on its own is a new command, not an answer.
        // EXACTLY claimed, not merely near. `VoiceCommand.parse` falls
        // back to a Levenshtein match, which is right for speech and
        // wrong here: "click home" is within budget of a binding, so
        // yielding on `parse` handed an ordinary button press to the
        // pointer — measured, 20 of 43 common labels went that way,
        // including Home, Share, Chat, More and Help. A pointer click
        // at wherever the cursor was left is the unlabelled, unrated
        // click this whole design exists to avoid.
        guard VoiceCommand.parse(text) == nil else { return nil }
        // And so is a command that is merely unfinished — saying "set volume
        // to" twice asked the question and then answered it with itself.
        guard Phrasebook.awaitingArgument(text, in: scope.context) == nil else { return nil }
        _pendingArgument = nil
        return pending.phrase
    }

    /// What to ask for, in the words of the phrase itself.
    private static func askFor(_ phrase: String) -> String {
        if phrase.contains("workspace") || phrase.contains("space") { return "Which workspace?" }
        if phrase.contains("tab") { return "Which tab?" }
        if phrase.contains("volume") { return "What level?" }
        if phrase.hasPrefix("type") || phrase.hasPrefix("write") || phrase.hasPrefix("say") {
            return "What should I type?"
        }
        if phrase.hasPrefix("search") || phrase.hasPrefix("find") { return "Search for what?" }
        if phrase.hasPrefix("go to") || phrase.contains("website") { return "Which site?" }
        return "\(phrase.prefix(1).uppercased() + phrase.dropFirst()) what?"
    }

    /// Accept a decision's nonce, once.
    enum NonceVerdict { case fresh, replayed, stale }

    private func acceptNonce(_ nonce: Nonce) -> NonceVerdict {
        // Freshness and clock skew, from the shared rule.
        guard nonce.isValid(against: lastDecisionNonce) else {
            return nonce.id == lastDecisionNonce?.id ? .replayed : .stale
        }

        // Every nonce still inside the window, not just the previous one.
        //
        // Comparing against the last decision alone is not replay
        // protection: answer two cards and the first nonce is replayable
        // again. The set was being written and never read, which is worse
        // than not having it — it reads like a guard.
        guard seenNonces[nonce.id] == nil else { return .replayed }

        lastDecisionNonce = nonce
        seenNonces[nonce.id] = nonce.timestamp
        // Prune by age, not by count. Emptying the whole set at some
        // arbitrary size would let every old id straight back in.
        let cutoff = Date().addingTimeInterval(-120)
        seenNonces = seenNonces.filter { $0.value > cutoff }
        return .fresh
    }

    /// Take away cards whose dialog is no longer on screen.
    ///
    /// Dismissing a sheet at the Mac used to leave its card stranded on the
    /// phone, and the queue only ever grew. Nothing pushed the withdrawal
    /// because nothing was watching for the dialog's disappearance — the
    /// watcher only ever reported dialogs arriving.
    func isPressing(_ id: String) -> Bool { pressingNow.contains(id) }

    /// Take the right to press this one, or find it already taken.
    ///
    /// Atomic because it runs on the actor: of two calls arriving
    /// together, exactly one gets `true`.
    func claimPress(_ id: String) -> Bool { pressingNow.insert(id).inserted }

    func releasePress(_ id: String) { pressingNow.remove(id) }

    private func sweepDeadDialogs() async {
        // Before anything ages out: a card about a dialog that is STILL ON
        // SCREEN is not stale, however long it has been there. A macOS
        // permission prompt waits indefinitely, and withdrawing its card at
        // five minutes left the prompt sitting on the Mac with no way to
        // answer it from the phone — and a push notification pointing at a
        // card that had been destroyed.
        for request in await store.everyPending()
        where request.kind == .appDialog || request.kind == .tccConsent {
            if DialogRegistry.shared.isLive(id: request.id) {
                if await store.hold(id: request.id) {
                    JevLog.write("[jev] holding “\(request.title)” — its dialog is still on screen")
                }
            } else {
                await store.release(id: request.id)
            }
        }

        // Cards the store has aged out. Nothing told the phone, so they sat
        // there unanswerable — and with the swipe gone, a TCC card (which
        // has no buttons at all) could not be got rid of by any means.
        for stale in await store.reapExpired() {
            DialogRegistry.shared.discard(id: stale.id)
            // Read the command BEFORE dropping it: for a spoken command the
            // card's title is the Phrasebook description — `Search for
            // “…”` — and every other line about that command is redacted
            // through `safeDescription` while this one was not. Say a
            // search with a card number in it, never answer the card, and
            // five minutes later the number went to jev.log in full.
            let parked = pendingCommands.removeValue(forKey: stale.id)
            await broadcastResolved(id: stale.id)
            JevLog.write("[jev] withdrew “\(CommandJournal.safeDescription(stale.title, parked?.command))”"
                + " — nobody answered it in time")
        }
        for request in await store.getAllPending() {
            guard request.kind == .appDialog || request.kind == .tccConsent else { continue }
            guard !DialogRegistry.shared.isLive(id: request.id) else { continue }
            _ = await store.resolve(id: request.id)
            DialogRegistry.shared.discard(id: request.id)
            await broadcastResolved(id: request.id)
            JevLog.write("[jev] withdrew “\(request.title)” — its dialog left the screen")
        }
    }

    /// The visible control this sentence is naming, if it is naming one.
    ///
    /// Deliberately strict. It matches an exact label, optionally behind a
    /// pressing verb and the odd article — "skip", "click skip", "press the
    /// Skip button". It will not match a sentence that merely contains the
    /// word, because "save the file to Downloads" is not a request to press
    /// Save, and a loose match here would be worse than the shortcut
    /// collision it exists to fix.
    /// The control name inside "click the Save button", or nil.
    ///
    /// Pure, and separated out so the strictness below can be asserted.
    static func controlPhrase(from text: String) -> String? {
        var phrase = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !phrase.isEmpty else { return nil }

        for verb in ["click on", "click", "press", "tap", "push", "hit", "choose", "select"]
        where phrase.hasPrefix(verb + " ") {
            phrase = String(phrase.dropFirst(verb.count + 1))
            break
        }
        if phrase.hasPrefix("the ") { phrase = String(phrase.dropFirst(4)) }
        if phrase.hasSuffix(" button") { phrase = String(phrase.dropLast(7)) }
        phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase.count >= 2 ? phrase : nil
    }

    /// Does exactly one visible control answer to this name?
    ///
    /// EXACT, deliberately, and this is a decision rather than an
    /// oversight. The obvious improvement is to score here the way
    /// `CuaBackend.bestMatch` scores at the executor — but that matcher
    /// has a prefix tier, and this gate runs BEFORE the phrasebook, so
    /// the prefix tier would eat the vocabulary. Measured against the
    /// real matcher, on pools that occur constantly:
    ///
    ///     "select all"  -> "all"  -> Allow        (a cookie banner)
    ///     "click it"    -> "it"   -> Italic
    ///     "click this"  -> "this" -> This Mac
    ///     "click here"  -> "here" -> Here's what's new
    ///
    /// Every one of those is a real phrasebook binding, and the first
    /// one presses Allow on a consent banner. "click this" and "click
    /// here" mean the POINTER; no label should ever outrank them.
    ///
    /// So the gate stays strict and only its folding is shared with the
    /// executor, via `CuaBackend.normalise` — curly apostrophes and
    /// ellipses, which are what made the two disagree about the same
    /// string.
    static func exactlyOneControl(named phrase: String, among labels: [String]) -> String? {
        let wanted = CuaBackend.normalise(phrase)
        let hits = labels.filter { CuaBackend.normalise($0) == wanted }
        // Two buttons with the same name is not a decision we get to make.
        return hits.count == 1 ? hits[0] : nil
    }

    private func controlMatching(_ text: String, in scope: Scope) async -> String? {
        // The phrasebook owns its own vocabulary.
        //
        // This gate runs BEFORE `VoiceCommand.parse`, so without this
        // line any binding whose object happens to match a visible
        // label is stolen — and strictness does not save it, which is
        // the part that surprised me. "click away" means Escape, and on
        // a page with a status control labelled "Away" the gate matched
        // it EXACTLY and pressed the button instead. Narrowing the
        // matcher would never have caught that; only precedence does.
        //
        // Same rule as `takePendingArgument`: anything that stands on
        // its own is a command, not a control name.
        // `neutral`, so the most common command on the system does not
        // fire a synchronous Apple Event at the browser from inside the
        // actor. `Phrasebook.neutral` was added in this same change for
        // exactly this reason and then not used here: every "click …"
        // paid an osascript round trip with no timeout, and a wedged
        // Chrome would have blocked every other command behind it.
        //
        // The cost: an app-scoped override is not consulted, so a
        // scoped binding whose name matches a visible control could be
        // out-competed by the control. That is a narrower hazard than
        // hanging the daemon, and `VocabularySelfTest` pins the global
        // vocabulary that matters.
        // The real scope, not `neutral`. The empty scope existed only so this
        // would not shell out from inside the actor; the scope was read once
        // before any stage ran, so there is nothing left to block on — and
        // "go to X" is now judged with the browser it was actually said to.
        guard !Phrasebook.claimsExactly(text, in: scope.context) else { return nil }
        guard let phrase = Self.controlPhrase(from: text) else { return nil }
        // The same reading every other stage saw, not a fresh one.
        let labels = scope.visibleLabels
        return Self.exactlyOneControl(named: phrase, among: labels)
    }

    /// Apply the saved mode for this app, if any, before troubling the human.
    /// - Parameter spokenIsPrivate: the spoken words are a VALUE the
    ///   person supplied, not a command they issued, so they must not
    ///   leave the Mac.
    /// "In Safari, close tab": re-point the scope at the app named, and
    /// drop the address from the sentence. Anything else passes through.
    private static func addressed(_ scope: Scope, said text: String) -> (Scope, String) {
        guard let addressed = scope.addressing(text, running: Scope.runningProcesses(), context: {
            Phrasebook.context(for: NSRunningApplication(processIdentifier: pid_t($0.pid)), host: nil)
        }) else { return (scope, text) }
        JevLog.write("[jev] addressed to \(addressed.scope.app)"
            + (addressed.scope.aim == nil ? "" : " (not in front; will be brought forward)"))
        return (addressed.scope, addressed.rest)
    }

    private func dispatch(_ parsed: VoiceCommand.Parsed, spokenAs text: String,
                          spokenIsPrivate: Bool = false, verdict: SafetyVerdict? = nil,
                          in scope: Scope) async -> ExecutionResult {
        // Every route out of here passes through `noteAmbiguity`, so a
        // refusal that said "there are three of those" is remembered
        // wherever it came from — the press-verb shortcut, the bare
        // word, or the model. Recording it at only one call site is how
        // the answer works after "click follow" and not after
        // "press follow".
        let result = await dispatchInner(parsed, spokenAs: text, spokenIsPrivate: spokenIsPrivate,
                                         verdict: verdict, in: scope)
        await noteAmbiguity(from: result, command: parsed.command, said: text,
                            saidIsPrivate: spokenIsPrivate)
        return result
    }

    /// Remember an "which of these?" so the next ordinal can answer it.
    private func noteAmbiguity(from result: ExecutionResult, command: Command,
                               said: String, saidIsPrivate: Bool = false) async {
        // Right-click goes through the same matcher, so it produces the
        // same "say which one" invitation. It was arming nothing, so
        // the question could not be answered — and had it armed, the
        // answer rebuilt a LEFT click, silently changing the verb.
        let target: (label: String, right: Bool)?
        switch command {
        case .clickControl(let label, let nth, _, _) where nth == nil:
            target = (label, false)
        case .rightClickControl(let label, let nth, _, _) where nth == nil:
            target = (label, true)
        default:
            target = nil
        }
        guard let target, result.status == .failed,
              let count = CuaBackend.ambiguityCount(in: result.reason) else {
            return
        }
        let window = await CuaBackend.lastAmbiguity.window(forLabel: target.label,
                                                           count: count)
        pendingChoice = (label: target.label, count: count, said: said,
                         rightClick: target.right, saidIsPrivate: saidIsPrivate,
                         window: window, asked: Date())
        // Take the badges down, because jev has just asked a question
        // that only IT can answer.
        //
        // With numbered badges up the phone owns a spoken number — it
        // taps that badge, and the Mac is told to leave ordinals alone.
        // So arming a choice while they are up produced a refusal
        // saying "say which one, like number two" whose own advice then
        // pressed an unrelated badge. Whoever is asking owns the
        // answer; asking clears the other claimant.
        Task { [weak self] in await self?.broadcastNumbers(false) }
    }

    private func dispatchInner(_ parsed: VoiceCommand.Parsed, spokenAs text: String,
                               spokenIsPrivate: Bool = false, verdict: SafetyVerdict? = nil,
                               in scope: Scope) async -> ExecutionResult {
        // Per app where the app is known: see `Scope.policyKey`.
        let aim = scope.aim
        guard let bundleId = scope.policyKey(for: parsed.command) else {
            return await requestApproval(for: parsed, spokenAs: text,
                                         spokenIsPrivate: spokenIsPrivate, aim: aim)
        }

        // A policy saved before typing was granted per app still counts,
        // where counting means refusing. See `AppPolicyStore.inherited`.
        let bucket = parsed.command.bundleIdentifier
        let inherited = bucket == bundleId ? nil
            : AppPolicyStore.inherited(bucket: bucket.flatMap { AppPolicyStore.shared.mode(for: $0) })
        let mode = inherited ?? AppPolicyStore.shared.effectiveMode(for: bundleId)
        if inherited == nil, bucket != bundleId,
           let old = bucket, AppPolicyStore.shared.mode(for: old) == .always {
            // Said once per command rather than kept quiet: this is a grant
            // the person made that jev is deliberately no longer honouring.
            JevLog.write("[jev] policy: “\(old)” was set to always, which no longer covers every app — "
                + "asking for \(bundleId) on its own")
        }

        // A web task never goes to the decision model, whatever the policy
        // says. Unknown bundle ids inherit the global mode, which defaults to
        // .auto — so without this, "order me another pack of coffee filters"
        // would be classified as routine and a sixty-action agent would run
        // loose on a signed-in shop with no card ever shown. Everything else
        // jev auto-runs is a single reversible act; this is a loop.
        if case .webTask = parsed.command, mode != .always {
            return await requestApproval(for: parsed, spokenAs: text,
                                         spokenIsPrivate: spokenIsPrivate, key: bundleId, aim: aim,
                                         reason: .browserTask)
        }

        switch mode {
        case .always:
            let result = await executor.execute(parsed.command, aim: scope.aim)
            // Report what actually happened. Substituting the description here
            // hid real failures behind a cheerful "Toggle Waz".
            return result

        case .never:
            JevLog.write("[jev] refused (never): \(CommandJournal.safeDescription(parsed.description, parsed.command))")
            return .failed(reason: "\(parsed.description) is set to never allow")

        case .auto:
            return await autoDecide(parsed, spokenAs: text, bundleId: bundleId,
                                    spokenIsPrivate: spokenIsPrivate, verdict: verdict, aim: aim)

        case .none:
            return await requestApproval(for: parsed, spokenAs: text,
                                         spokenIsPrivate: spokenIsPrivate, key: bundleId, aim: aim)
        }
    }

    /// Hand the request to the decision model.
    ///
    /// The question is deliberately narrow. An earlier version offered "ask the
    /// human" as one of the choices and invited Jev to pick it whenever a
    /// person's judgement might help — so it deferred on everything, including
    /// "scroll down", and auto was indistinguishable from ask. Asking instead
    /// whether the action is routine and reversible gives usable signal.
    private func autoDecide(_ parsed: VoiceCommand.Parsed, spokenAs text: String, bundleId: String,
                            spokenIsPrivate: Bool = false,
                            verdict: SafetyVerdict? = nil,
                            aim: Aim? = nil) async -> ExecutionResult {
        // Already judged, in the same call that resolved the sentence. The
        // literal parser's commands never went through that call, so they
        // still ask here.
        if let verdict {
            return await act(on: verdict, parsed, spokenAs: text, bundleId: bundleId,
                             spokenIsPrivate: spokenIsPrivate, from: "intent", aim: aim)
        }
        guard let apiKey = JevAPI.loadAPIKey() else {
            return await requestApproval(for: parsed, spokenAs: text,
                                         spokenIsPrivate: spokenIsPrivate, key: bundleId, aim: aim,
                                         reason: .cannotJudge)
        }

        let appName = AppCatalog.shared.all.first { $0.bundleIdentifier == bundleId }?.name ?? bundleId
        let state: [String: Any] = [
            // The finishing route asks "what should I type?" and the
            // answer is whatever the person said next — a search term,
            // a name, a password. The log goes to great lengths not to
            // record it and the journal marks it `unparsed` so it never
            // reaches `commands.jsonl`, and then this line posted the
            // whole sentence to the decider anyway. The description
            // ("Type into the focused field") says what is being asked
            // without saying what was typed.
            "spoken_request": spokenIsPrivate ? parsed.description : text,
            "interpreted_as": parsed.description,
            "target": appName,
            "already_allowed": Array(AppPolicyStore.shared.all.filter { $0.value == .always }.keys),
            "explicitly_blocked": Array(AppPolicyStore.shared.all.filter { $0.value == .never }.keys),
        ]

        let questions: [String: JevAPI.Question] = [
            "routine": .noul(instructions: SafetyVerdict.routineQuestion),
            "destructive": .noul(instructions: SafetyVerdict.destructiveQuestion),
        ]

        let result = await JevAPI.ask(state: state, questions: questions, apiKey: apiKey)
        guard case .success(let answers) = result else {
            JevLog.write("[jev] auto: Jev unavailable, asking you")
            return await requestApproval(for: parsed, spokenAs: text,
                                         spokenIsPrivate: spokenIsPrivate, key: bundleId, aim: aim,
                                         reason: .cannotJudge)
        }

        let judged = SafetyVerdict(routine: answers.noul("routine") ?? 0,
                                   destructive: answers.noul("destructive") ?? 1)
        return await act(on: judged, parsed, spokenAs: text, bundleId: bundleId,
                         spokenIsPrivate: spokenIsPrivate, from: "auto", aim: aim)
    }

    /// Run it or ask, on one verdict, wherever the verdict came from.
    private func act(on verdict: SafetyVerdict, _ parsed: VoiceCommand.Parsed, spokenAs text: String,
                     bundleId: String, spokenIsPrivate: Bool, from source: String,
                     aim: Aim?) async -> ExecutionResult {
        JevLog.write(String(format: "[jev] %@: %@ routine=%.2f destructive=%.2f", source,
                            CommandJournal.safeDescription(parsed.description, parsed.command),
                            verdict.routine, verdict.destructive))
        guard verdict.allowsUnattended else {
            return await requestApproval(for: parsed, spokenAs: text,
                                         spokenIsPrivate: spokenIsPrivate, key: bundleId, aim: aim,
                                         reason: verdict.looksDestructive ? .hardToUndo : .notRoutine)
        }
        let executed = await executor.execute(parsed.command, humanApproved: true, aim: aim)
        return executed.status == .ok
            ? .ok(reason: parsed.description)
            : executed
    }

    /// Park a command and put an approval in front of the human.
    /// Answer one Claude Code permission request.
    ///
    /// The hook gives up after five seconds, so the human path is a race we
    /// have to be honest about: the card goes to the phone either way, and if
    /// you answer within four seconds we use your answer. If you do not, we
    /// fail closed and Claude Code falls back to its own prompt — the card
    /// stays on the phone, so whichever you reach first is the one that acts.
    func decidePermission(_ body: String) async -> String {
        func reply(_ allow: Bool, _ reason: String) -> String {
            let payload: [String: Any] = ["allow": allow, "reason": reason]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return String(data: data, encoding: .utf8)
                ?? #"{"allow":false,"reason":"could not encode a decision"}"#
        }

        guard let data = body.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return reply(false, "jev could not read the request")
        }

        // Claude Code names the tool in `name` and what it is acting on in
        // `resource`; the rest varies by tool, so it is summarised, not parsed.
        let tool = (request["name"] as? String) ?? "a tool"
        let resource = (request["resource"] as? String) ?? ""
        let args = (request["args"] as? [Any])?.map { String(describing: $0) } ?? []
        let detail = [resource, args.joined(separator: " ")]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let summary = detail.isEmpty ? tool : "\(tool): \(detail)"

        let bundleId = "com.anthropic.claude-code"
        // The SHAPE, not the payload. `summary` is the tool name plus
        // whatever it is acting on — a Bash command line, the text of a
        // Write — and it went into `jev.log` in full. That is the one
        // place a value the person never typed reached the log
        // unredacted, and a log is exactly where a token pasted into a
        // command goes to be forgotten about. The card still shows the
        // whole thing; the card is on their phone, not in a file.
        JevLog.write("[jev] permission asked: \(tool) (\(JevLog.shape(detail)))")

        // 1. Policy. An explicit choice you already made needs no model and
        //    no phone.
        switch AppPolicyStore.shared.mode(for: bundleId) {
        case .always:
            JevLog.write("[jev] permission allowed by policy")
            return reply(true, "You always allow Claude Code")
        case .never:
            JevLog.write("[jev] permission denied by policy")
            return reply(false, "You never allow Claude Code")
        default:
            break
        }

        // 2. The card goes to the phone now, so it is already there whether
        //    or not the wait below runs out.
        let id = UUID().uuidString
        let approval = ApprovalRequest(
            id: id,
            kind: .agentToolPrompt,
            title: summary,
            bodyText: "Claude Code is asking to use \(tool)."
                + (detail.isEmpty ? "" : "\n\(detail)"),
            options: [
                ApprovalOption(id: "once", label: "Allow once", riskLevel: .low),
                ApprovalOption(id: "always", label: "Always allow Claude Code", riskLevel: .medium),
                ApprovalOption(id: "deny", label: "Deny", riskLevel: .low),
            ],
            originatingApp: ApplicationInfo(name: "Claude Code", bundleIdentifier: bundleId),
            timestamp: Date(),
            screenshotReference: nil,
            handoffOnly: false
        )
        guard await store.addDeduplicated(approval) else {
            return reply(false, "Already waiting for your answer on that")
        }
        await broadcast(event: "approval", request: approval)

        // 3. Wait, but not longer than the hook will. Four seconds leaves it
        //    a second to write its own answer.
        awaitedPermissions.insert(id)
        var answer = ""
        for _ in 0..<40 {
            if let given = permissionAnswers.removeValue(forKey: id) { answer = given; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // One more look, after the last sleep rather than before it.
        //
        // The loop checked and then slept, so an answer written during that
        // final 100 ms was dropped on the floor by the cleanup below — while
        // `/api/decide` had already replied "Told Claude Code" to the phone.
        // The phone said it was answered and Claude Code was told nobody
        // answered.
        if answer.isEmpty, let late = permissionAnswers.removeValue(forKey: id) { answer = late }
        awaitedPermissions.remove(id)
        permissionAnswers.removeValue(forKey: id)

        switch answer {
        case "once":
            JevLog.write("[jev] permission allowed from the phone")
            return reply(true, "You allowed it from your phone")
        case "always":
            AppPolicyStore.shared.set(.always, for: bundleId)
            JevLog.write("[jev] permission allowed, and remembered")
            return reply(true, "You allowed Claude Code from now on")
        case "deny":
            JevLog.write("[jev] permission denied from the phone")
            return reply(false, "You denied it from your phone")
        default:
            // Nobody answered in time. Fail closed, and TAKE THE CARD DOWN.
            //
            // Leaving it up would be a lie: the hook has already told Claude
            // Code no and it has shown its own prompt on the Mac, so a later
            // tap here cannot retroactively allow anything. Worse, the id is
            // no longer awaited, so that tap would fall through to the
            // generic agent-prompt path and try to press a button in an app
            // that was never involved.
            _ = await store.resolve(id: id)
            await broadcastResolved(id: id)
            JevLog.write("[jev] permission unanswered in 4s — withdrew the card, answer on the Mac")
            return reply(false, "No answer from your phone in time — asking on the Mac instead")
        }
    }

    /// Called by /api/decide. Returns true when this id was a permission
    /// request rather than a parked command, so the caller stops there.
    func resolvePermission(id: String, optionId: String) -> Bool {
        guard awaitedPermissions.contains(id) else { return false }
        permissionAnswers[id] = optionId
        return true
    }

    /// Why a card is in front of you.
    ///
    /// Every card said the same thing — "… has not been allowed yet" —
    /// whatever had actually stopped the command, and only one of these
    /// reasons is about permission at all. So a sentence jev merely
    /// half-caught raised a card blaming a setting, which is how "always
    /// allow" came to look broken: the person had allowed it, the card still
    /// said they had not, and the real reason (0.54 confident) was in a log
    /// nobody reads.
    ///
    /// Permission answers "may I". It was never the answer to "did I hear
    /// you right", and the card should not pretend otherwise.
    enum ApprovalReason: Sendable, Equatable {
        /// Understood; this app or action has not been allowed.
        case notAllowed
        /// Heard, but not well enough to act on the guess.
        case halfHeard(confidence: Double)
        /// Understood, and it looks hard to undo.
        case hardToUndo
        /// Allowed or not, a browser task is a loop rather than one act.
        case browserTask
        /// Nothing could judge it: no key, or Jev unreachable.
        case cannotJudge
        /// Judged, and not clearly routine.
        case notRoutine

        /// Pure, and asserted: this is the sentence the person reads at 2am
        /// deciding whether to tap Allow.
        func body(said: String, appName: String, description: String) -> String {
            let heard = "You said “\(said)”."
            switch self {
            case .notAllowed:
                return "\(heard)\njev can do this, but \(appName) has not been allowed yet."
            case .halfHeard(let confidence):
                return "\(heard)\njev is only \(Int((confidence * 100).rounded()))% sure that means "
                    + "“\(description)”, so it would rather ask than guess. This is not a permission "
                    + "setting — allowing \(appName) will not stop it."
            case .hardToUndo:
                return "\(heard)\njev understood this, and thinks it may be hard to undo."
            case .browserTask:
                return "\(heard)\nA browser task clicks its own way through a page, so jev asks every "
                    + "time no matter what is allowed."
            case .cannotJudge:
                return "\(heard)\njev could not reach the decider to judge this, so it is asking you "
                    + "instead."
            case .notRoutine:
                return "\(heard)\njev did not think this was routine enough to do on its own."
            }
        }
    }

    private func requestApproval(for parsed: VoiceCommand.Parsed, spokenAs text: String,
                                 spokenIsPrivate: Bool = false,
                                 key: String? = nil,
                                 aim: Aim? = nil,
                                 reason: ApprovalReason = .notAllowed) async -> ExecutionResult {
        let id = UUID().uuidString
        // What "always" and "never" on the card will be granted for.
        let key = key ?? parsed.command.bundleIdentifier
        let friendly: [String: String] = [
            "system.gesture": "scrolling",
            "system.workspace": "workspace switching",
            "system.pointer": "clicking on screen",
            "system.keyboard": "typing",
            "system.browser": "opening a page",
            "system.webtask": "acting in your browser",
        ]
        let appName = key.flatMap { bundleId in
            friendly[bundleId] ?? AppCatalog.shared.all.first { $0.bundleIdentifier == bundleId }?.name
        } ?? "this app"

        let request = ApprovalRequest(
            id: id,
            kind: .spokenCommand,
            title: parsed.description,
            bodyText: reason.body(said: text, appName: appName, description: parsed.description),
            options: [
                ApprovalOption(id: "once", label: "Allow", riskLevel: .low),
                ApprovalOption(id: "deny", label: "Deny", riskLevel: .low),
            ],
            originatingApp: ApplicationInfo(
                name: appName,
                // "unknown.bundle", the same string `DialogWatcher` uses
                // and the one the phone checks before offering to
                // remember an app. Spelled "unknown" here, the guard did
                // not fire: long-pressing an unattributable spoken
                // command and choosing "never allow this app" wrote a
                // policy keyed "unknown", which then applied to every
                // other command jev could not attribute either.
                bundleIdentifier: key ?? "unknown.bundle"
            ),
            timestamp: Date(),
            screenshotReference: nil,
            handoffOnly: false
        )

        // Park it only once there is a card to answer. Set before the
        // dedup guard, a suppressed duplicate left a command sitting under
        // an id that no card would ever carry, for the life of the process.
        guard await store.addDeduplicated(request) else {
            JevLog.write("[jev] duplicate approval suppressed: \(CommandJournal.safeDescription(parsed.description, parsed.command))")
            return .ok(reason: "Already waiting for your answer on that")
        }
        pendingCommands[id] = (command: parsed.command, said: text,
                               saidIsPrivate: spokenIsPrivate, aim: aim, key: key)
        await broadcast(event: "approval", request: request)
        JevLog.write("[jev] asking for approval: \(CommandJournal.safeDescription(parsed.description, parsed.command))")
        return .ok(reason: "Needs your approval — check the Approvals tab")
    }

    /// Whether this id was a report, claiming it if so.
    func claimWebReport(id: String) -> Bool { webReports.remove(id) != nil }

    /// Whether this id was a mid-task question. Records the answer if so.
    func resolveWebConsent(id: String, optionId: String) -> Bool {
        guard awaitedWebConsent.contains(id) else { return false }
        webConsentAnswers[id] = optionId
        return true
    }

    /// Ask, mid-task, before clicking something consequential.
    ///
    /// This is the one place a browser task stops and waits for a person.
    /// It works because actors are reentrant: the task is suspended inside
    /// `Task.sleep` below, which lets `/api/decide` land on this same actor
    /// and write the answer. Take the sleep away and nothing could ever
    /// answer this.
    func askWebConsent(about label: String, picture: String?) async -> WebAgent.Consent {
        let id = UUID().uuidString
        let request = ApprovalRequest(
            id: id,
            kind: .spokenCommand,
            title: WebSafety.approvalQuestion(for: label),
            bodyText: "A browser task wants to click this. It will not do it unless you say so.",
            options: [
                ApprovalOption(id: "yes", label: "Click it", riskLevel: .high),
                ApprovalOption(id: "no", label: "Stop", riskLevel: .low),
            ],
            originatingApp: ApplicationInfo(name: "Google Chrome",
                                            bundleIdentifier: "com.google.Chrome"),
            timestamp: Date(),
            screenshotReference: picture)

        // A suppressed duplicate would leave this waiting on a card that was
        // never shown — the store drops a same-title card within two minutes,
        // and clicking the same button twice in one task is exactly that.
        guard await store.addDeduplicated(request) else {
            JevLog.write("[jev] web consent not asked: an identical card is already up")
            return .noAnswer
        }
        awaitedWebConsent.insert(id)
        await broadcast(event: "approval", request: request)
        JevLog.write("[jev] asking before clicking in the browser")

        var answer = ""
        for _ in 0..<Self.webConsentPolls {
            if let given = webConsentAnswers.removeValue(forKey: id) { answer = given; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        // One more look after the final sleep rather than before it, or an
        // answer written in that last half-second is dropped while the phone
        // has already been told it was received.
        if answer.isEmpty, let late = webConsentAnswers.removeValue(forKey: id) { answer = late }
        awaitedWebConsent.remove(id)
        webConsentAnswers.removeValue(forKey: id)

        // Take the card down either way: unanswered, it is a question about a
        // task that has already stopped.
        _ = await store.resolve(id: id)
        await broadcastResolved(id: id)

        switch answer {
        case "yes": JevLog.write("[jev] you allowed it"); return .yes
        case "no": JevLog.write("[jev] you stopped it"); return .no
        default: JevLog.write("[jev] nobody answered; the task stopped"); return .noAnswer
        }
    }

    /// Answer a parked command. Returns nil when the id is not one of ours.
    func resolveCommandApproval(id: String, optionId: String) async -> ExecutionResult? {
        // CLAIM it first, in one synchronous step.
        //
        // Reading and then removing with an `await` in between is not a
        // claim: two /api/decide calls landing inside that hop both see
        // the command and both run it. "A parked command runs at most
        // once" has to be structural, not a matter of timing.
        guard let parked = pendingCommands.removeValue(forKey: id) else { return nil }
        let command = parked.command
        // The store is the clock. `pendingCommands` has no expiry of its
        // own and only the 2-second sweep prunes it, so a card that aged
        // out still ran its command for up to two seconds after the store
        // had already stopped acknowledging it — the one path where
        // "expired means expired" was not true.
        guard await store.get(id: id) != nil else {
            await broadcastResolved(id: id)
            return .failed(reason: "That one sat too long — say it again")
        }

        // The key the card was raised for, so "always" grants what it showed.
        let bundleId = parked.key

        switch optionId {
        case "deny":
            JevLog.write("[jev] approval denied for \(id)")
            return .ok(reason: "Denied")
        case "never":
            if let bundleId { AppPolicyStore.shared.set(.never, for: bundleId) }
            return .ok(reason: "Will never allow this app")
        case "always":
            if let bundleId { AppPolicyStore.shared.set(.always, for: bundleId) }
        case "auto":
            if let bundleId { AppPolicyStore.shared.set(.auto, for: bundleId) }
        case "once":
            break
        default:
            // Named, not assumed. `default: break` fell through to
            // running the command, so any id that was not one of these —
            // a typo, an older client, a replayed body with the id
            // changed — executed a parked command as though the person
            // had approved it. The card only ever offers these.
            JevLog.write("[jev] approval for \(id) named an unknown option “\(optionId)”")
            return .failed(reason: "That is not one of the choices on the card")
        }

        // Re-aim at what was meant when it was said, not at what is in front
        // by the time the card was answered.
        let result = await executor.execute(command, humanApproved: true, aim: parked.aim)
        // A sequence reports its own label as the reason, and that label is
        // the description — "Search for “5555 4444 3333”".
        JevLog.write("[jev] approved (\(optionId)) -> \(result.status.rawValue): \(CommandJournal.safeDescription(result.reason, command))")
        // The card path runs the command HERE, not through `dispatch`,
        // so the ambiguity had to be recorded here too. Without this
        // line the refusal asked "which one?" on every Mac whose
        // pointer commands need a card — which is every Mac with no
        // API key, and every Mac set to "ask me" — and no answer could
        // ever be understood.
        // The sentence the person actually said, parked with the
        // command — not the refusal jev printed about it.
        await noteAmbiguity(from: result, command: command, said: parked.said,
                            saidIsPrivate: parked.saidIsPrivate)
        return result
    }

    private func broadcastResolved(id: String) async {
        // Built, not interpolated. On the unknown-id path this `id` is
        // whatever the phone POSTed — it never came from the store — so
        // an id containing a quote could close the string and append
        // its own keys, and the last `type` wins in JSON.parse. That is
        // a way to pop the "enter your password" sheet on every paired
        // phone. It needs the bearer token, so it is depth rather than
        // a hole, but it is the one place a network string is spliced
        // into JSON by hand.
        let payload: [String: Any] = ["type": "resolved", "id": id]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: data, encoding: .utf8) else { return }
        for socket in pruneSockets() {
            await socket.send(text: message)
        }
    }

    /// Whether anything is actually listening. Checked synchronously, because
    /// the caller needs an answer now in order to report honestly.
    nonisolated var hasConnectedPhone: Bool {
        Self.socketCountLock.lock()
        defer { Self.socketCountLock.unlock() }
        return Self.connectedSockets > 0
    }

    private nonisolated(unsafe) static var connectedSockets = 0
    private static let socketCountLock = NSLock()

    /// The competing transcriptions of the utterance being handled right now.
    /// One at a time by construction: you cannot speak two commands at once.
    private var lastReadings: (chosen: String, all: [String])?

    func rememberReadings(for chosen: String, all: [String]) {
        lastReadings = (chosen, all.filter { $0 != chosen })
    }

    func readings(for text: String) -> [String] {
        guard let lastReadings, lastReadings.chosen == text else { return [] }
        return lastReadings.all
    }

    /// Show a scanned form on the phone as a Spec it can render natively.
    ///
    /// The shape is json-render's: flat `elements` keyed by id, a `root`, and
    /// a `state` map that the inputs bind into. We take the format and not
    /// the library — the library is React and this app is four static files —
    /// but keeping the contract means the phone renderer stays a dumb
    /// interpreter, and a DOM-derived field list from the browser backend can
    /// emit the same thing without the phone learning a second format.
    ///
    /// Beats shipping a screenshot of a form: you get a real keyboard, real
    /// autofill, and a field you can name out loud.
    /// Tell the phone to draw numbers over its picture. It fetches the list
    /// itself from /api/controls — the Mac never draws anything.
    func broadcastNumbers(_ on: Bool) async {
        // Carry the intent. Sending the same message for both and letting the
        // phone toggle meant "show guides" HID the numbers whenever they were
        // already up — which is exactly what happens after pressing the
        // button, so the voice command looked broken every time.
        let payload: [String: Any] = ["type": "numbers", "show": on]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        for socket in pruneSockets() { await socket.send(text: json) }
    }

    func broadcastForm(_ fields: [FormScanner.Field]) async {
        var state: [String: String] = [:]
        var elements: [String: Any] = [:]
        var children: [String] = []

        for (index, field) in fields.enumerated() {
            let id = "f\(index)"
            state[id] = ""
            children.append(id)
            elements[id] = [
                "component": "Input",
                "props": [
                    "label": field.label,
                    // What the Mac will be asked to fill. Sent separately
                    // from the label because Jev may have named this field
                    // for you, and the Mac has never heard that name.
                    "target": field.realLabel,
                    "secret": field.secret,
                    // The AX role is the best keyboard hint we have.
                    "kind": field.kind,
                    "$bindState": id,
                ] as [String: Any],
            ]
        }

        let submitId = "submit"
        children.append(submitId)
        elements[submitId] = [
            "component": "Button",
            "props": ["label": "Fill on the Mac", "action": "submit"] as [String: Any],
        ]
        elements["root"] = [
            "component": "Panel",
            "props": ["title": "Fill this in"] as [String: Any],
            "slots": ["children": children],
        ]

        let spec: [String: Any] = ["root": "root", "state": state, "elements": elements]
        let payload: [String: Any] = ["type": "spec", "spec": spec]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        JevLog.write("[jev] sending a \(fields.count)-field form to the phone as a spec")
        for socket in pruneSockets() { await socket.send(text: json) }
    }

    /// Say what a web task is doing, step by step.
    ///
    /// A web task changes nothing on the Mac's screen — it runs in a tab
    /// nobody is looking at — so without this the phone shows a spinner for a
    /// minute and gives no reason to believe anything is happening. Retries
    /// are marked rather than hidden: two lines with the same number are the
    /// truth about what jev did.
    func broadcastWebProgress(step: Int, operation: String, target: String,
                              isRetry: Bool, finished: Bool) async {
        let payload = WebAgent.progressMessage(step: step, operation: operation,
                                               target: target, isRetry: isRetry,
                                               finished: finished)
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        for socket in pruneSockets() { await socket.send(text: json) }
    }

    /// Put a card on the phone saying how a web task ended.
    ///
    /// Informational. The task is already over — command approval in jev is
    /// park-and-return, so there is no caller left to resume — and a card
    /// that looked like it could resume one would be a lie. Its single option
    /// dismisses it, and `webReports` is what stops that tap being taken for
    /// a button press in a dialog that does not exist.
    func reportWebOutcome(title: String, body: String, picture: String?) async {
        let id = UUID().uuidString
        let request = ApprovalRequest(
            id: id,
            kind: .spokenCommand,
            title: title,
            bodyText: body,
            options: [ApprovalOption(id: "ok", label: "OK", riskLevel: .low)],
            originatingApp: ApplicationInfo(name: "Google Chrome",
                                            bundleIdentifier: "com.google.Chrome"),
            timestamp: Date(),
            screenshotReference: picture)
        guard await store.addDeduplicated(request) else { return }
        webReports.insert(id)
        await broadcast(event: "approval", request: request)
        JevLog.write("[jev] web task ended: \(title)\(picture == nil ? "" : " (with a picture)")")
    }

    /// Ask the phone to open its text sheet, aimed at a named field.
    func broadcastInputRequest(field: String, secret: Bool) async {
        let payload: [String: Any] = ["type": "needInput", "field": field, "secret": secret]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        for socket in pruneSockets() { await socket.send(text: json) }
    }

    private func addSocket(_ session: WebSocketSession) {
        sockets.append(session)
        pruneSockets()
    }

    /// Drop sockets the phone has already abandoned, and publish the count so
    /// a command can tell, synchronously, whether anyone is listening.
    @discardableResult
    private func pruneSockets() -> [WebSocketSession] {
        sockets = sockets.filter(\.isOpen)
        Self.socketCountLock.lock()
        Self.connectedSockets = sockets.count
        Self.socketCountLock.unlock()
        return sockets
    }

    // MARK: - Audit

    private func audit(request: ApprovalRequest, decision: Decision, result: ExecutionResult) {
        let line: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "app": request.originatingApp.bundleIdentifier,
            "title": request.title,
            "decision": String(describing: decision.value),
            "by": String(describing: decision.source),
            "reason": decision.reason,
            "result": String(describing: result.status),
            // The file that outlives the session must not say "ok"
            // about a press the Mac ignored. `landed` is the whole
            // reason that distinction exists; leaving it out of the
            // durable record kept the claim alive in the one place
            // nobody can correct it later.
            "landed": result.landed ? "yes" : "no",
            "detail": result.reason,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/jev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("audit.jsonl")

        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            // Created 0600, not written-then-chmodded: `audit.jsonl` was
            // the one file with no attributes at all, and it holds every
            // dialog title, decision and reason. The launch-time sweep
            // would only have caught it on the NEXT start, so it sat
            // world-readable for the whole session it was born in.
            FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: - Helpers

    /// The PWA lives next to the binary inside Jev.app, or in the repo during
    /// `swift run`. Checking both means the dev loop needs no extra setup.
    static func webRoot() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/web", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled.path }

        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // jevd
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("web", isDirectory: true)
        if FileManager.default.fileExists(atPath: repo.path) { return repo.path }

        return nil
    }

    static func tailnetAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var found: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            // Tailscale hands out addresses from the 100.64.0.0/10 CGNAT range.
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4, parts[0] == 100, parts[1] >= 64, parts[1] <= 127 {
                found = ip
                break
            }
        }
        return found
    }
}
