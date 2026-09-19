import Foundation
import AppKit
import JevCore
import JevAX
import JevCapture
import JevDecide
import JevServer

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
    private var pendingCommands: [String: Command] = [:]
    /// How the phone should draw the current numbers: bare numbers by default,
    /// outlines only when asked. Eighty boxes over a screenshot hide the thing
    /// you are trying to look at.
    private var hintMode = "numbers"

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
            let host = Self.tailnetAddress() ?? "127.0.0.1"
            JevLog.write("[jev] Server listening on \(host):\(port)")
            // Print the link outright. Reconstructing it by hand from a token
            // file is how the last pairing broke.
            // The same URL the menu bar hands out — an https MagicDNS origin
            // when serve is up. The old line hardcoded http://<ip>:<port>,
            // which is not a secure context and so cannot do voice or push.
            JevLog.write("[jev] Pair your phone: \(Tailnet.pairingURL(token: token, localPort: port))")
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
        Transcription.requestSpeechAuthorization()

        guard AccessibilityPermission.isTrusted() else {
            JevLog.write("[jev] Accessibility is not granted, so no dialogs can be seen or pressed.")
            // Ask macOS to show the real prompt rather than only logging. This
            // also registers the app under its current code signature, which a
            // stale entry left over from an earlier signing identity does not.
            _ = AccessibilityPermission.requestTrust()
            JevLog.write("[jev] Requested Accessibility. Approve it, then relaunch Jev.")
            return
        }

        // Numbers taken in one app are meaningless in another.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard !Hints.shared.all.isEmpty else { return }
            Hints.shared.clear()
            Task { await self?.broadcastHintsCleared() }
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
        let watcher = DialogWatcher { [weak self] request in
            guard let self else { return }
            Task { await self.handle(request) }
        }
        self.watcher = watcher
        watcher.start()
        JevLog.write("[jev] Watching for dialogs.")
    }

    // MARK: - The loop

    /// A dialog appeared. Decide what to do with it.
    private func handle(_ request: ApprovalRequest) async {
        // An explicit "Never allow" for this app is the one case where a
        // dialog should not reach you. Policy no longer denies merely-unknown
        // apps, so this is what keeps the noisy ones quiet.
        let bundleId = request.originatingApp.bundleIdentifier
        if AppPolicyStore.shared.effectiveMode(for: bundleId) == .never, !request.handoffOnly {
            JevLog.write("[jev] ignoring dialog from \(request.originatingApp.name) — set to never")
            return
        }

        let decision = await pipeline.decide(request: request, dialogText: request.bodyText)
        JevLog.write("[jev] dialog “\(request.title)” from \(request.originatingApp.name): "
            + "\(decision.value) by \(decision.source) — \(decision.reason)")

        // Handoff-only requests (TCC consent sheets) are never pressed, whatever
        // the decision says — macOS ignores synthetic input on them.
        if request.handoffOnly {
            await escalate(request, note: "System permission dialog — needs you in Screen Sharing.")
            return
        }

        switch decision.value {
        case .allow:
            guard let optionId = decision.chosenOptionId else {
                await escalate(request, note: "Decider allowed but named no button.")
                return
            }
            let result = await executor.execute(.pressButton(requestId: request.id, optionId: optionId))
            audit(request: request, decision: decision, result: result)
            if result.status == .failed {
                await escalate(request, note: "Auto-press failed: \(result.reason)")
            }

        case .deny:
            audit(request: request, decision: decision, result: .ok(reason: "Denied by \(decision.source); left alone."))

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

        server.onDecide { [weak self] requestId, optionId, _ in
            guard let self else { return .failed(reason: "Shutting down") }

            // A parked voice command resolves here, not through the AX path.
            if let result = await self.resolveCommandApproval(id: requestId, optionId: optionId) {
                _ = await store.resolve(id: requestId)
                await self.broadcastResolved(id: requestId)
                return result
            }

            guard let request = await store.get(id: requestId) else {
                return .failed(reason: "No pending approval with that id")
            }
            let command: Command = request.kind == .agentToolPrompt
                ? .answerAgentPrompt(requestId: requestId, optionId: optionId)
                : .pressButton(requestId: requestId, optionId: optionId)
            let result = await executor.execute(command)
            if result.status == .ok {
                _ = await store.resolve(id: requestId)
                await self.broadcastResolved(id: requestId)
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
            let result = Pointer.scroll(dx: dx * frame.width, dy: dy * frame.height,
                                        at: CGPoint(x: nx * frame.width, y: ny * frame.height))
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

        server.onDisplayInfo {
            let frame = Pointer.displayBounds()
            let payload: [String: Any] = [
                "width": frame.width,
                "height": frame.height,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        // A tap on the screen view. Coordinates arrive normalised 0..1 so the
        // phone never has to know the display size or the JPEG scale.
        server.onTap { nx, ny, kind in
            let frame = Pointer.displayBounds()
            let x = nx * frame.width
            let y = ny * frame.height
            let result = Pointer.perform(kind, at: CGPoint(x: x, y: y))
            let payload: [String: Any] = ["ok": result.status == .ok, "reason": result.reason]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return String(data: data, encoding: .utf8) ?? #"{"ok":false}"#
        }

        server.onCommand { [weak self] text in
            guard let self else { return .failed(reason: "Shutting down") }

            if let parsed = VoiceCommand.parse(text) {
                let result = await self.dispatch(parsed, spokenAs: text)
                // The phone cannot draw boxes it has not been told about.
                switch parsed.command {
                case .showHints, .showHintsForApp, .showHintsEverywhere, .showHintsScoped:
                    if result.status == .ok {
                        // "show boxes" asks for outlines; everything else is
                        // numbers alone.
                        await self.setHintMode(text.lowercased().contains("box") ? "boxes" : "numbers")
                        await self.broadcastHints()
                    }
                case .showHintBox(let number):
                    if result.status == .ok { await self.broadcastSingleBox(number) }
                default:
                    break
                }
                switch parsed.command {
                case .selectHint, .hideHints:
                    Hints.shared.clear()
                    await self.broadcastHintsCleared()
                default:
                    break
                }
                return result
            }

            if let prefix = policy.allowedCommandPrefixes.first(where: { text.hasPrefix($0) }) {
                return await executor.execute(.runCommand(allowlistedPrefix: prefix, fullCommand: text))
            }

            // The literal parser only knows open/quit. Anything else goes to
            // Jev, which picks from things that actually exist on this Mac —
            // installed apps and the controls really on screen — so it can only
            // ever name something actionable.
            guard let apiKey = JevAPI.loadAPIKey() else {
                return .failed(reason: "Did not understand “\(text)”, and no Jev key is configured to interpret it")
            }

            switch await JevIntent.resolve(transcript: text,
                                           alternatives: await self.readings(for: text),
                                           apiKey: apiKey) {
            case .failure(let error):
                JevLog.write("[jev] intent: \(error.description)")

                // No single known action fits. Before giving up, let Jev try to
                // build one out of several — "open a new tab and search for X"
                // is two things jev can already do, in an order nobody wrote
                // down. A composed plan is a guess, so it always goes to you
                // for approval rather than straight to the machine.
                if let plan = await JevPlan.compose(transcript: text, apiKey: apiKey) {
                    let parsed = VoiceCommand.Parsed(
                        command: .sequence(label: plan.description, steps: plan.steps),
                        description: plan.description)
                    return await self.requestApproval(for: parsed, spokenAs: text)
                }

                return .failed(reason: "Did not understand “\(text)” — \(error.description)")

            case .success(let resolution):
                JevLog.write("[jev] intent: \(resolution.description) confidence=\(String(format: "%.2f", resolution.confidence)) safety=\(String(format: "%.2f", resolution.safety))")

                // A guess is not a mandate. Anything Jev is unsure of, or calls
                // unsafe, goes to you rather than straight to the machine.
                guard resolution.confidence >= 0.55, resolution.safety >= 0.5 else {
                    let parsed = VoiceCommand.Parsed(command: resolution.command, description: resolution.description)
                    return await self.requestApproval(for: parsed, spokenAs: text)
                }

                let parsed = VoiceCommand.Parsed(command: resolution.command, description: resolution.description)
                return await self.dispatch(parsed, spokenAs: text)
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

            let result = await SpeechRecognizer().transcribe(audioURL: audioURL)
            switch result {
            case .success(let heard):
                if heard.alternatives.isEmpty {
                    JevLog.write("[jev] voice: heard \"\(heard.best)\"")
                } else {
                    JevLog.write("[jev] voice: heard \"\(heard.best)\" "
                        + "(also: \(heard.alternatives.joined(separator: " | ")))")
                }
                let chosen = await SpeechRepair.choose(heard, apiKey: JevAPI.loadAPIKey())
                // Kept for the command handler that runs next in this same
                // request: if nothing parses, Jev should see every reading,
                // not just the one that failed.
                await self.rememberReadings(for: chosen, all: [heard.best] + heard.alternatives)
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
            let command: Command = field.map { .fillField(label: $0, text: text) }
                ?? .typeText(text: text)
            let result = await executor.execute(command, humanApproved: true)
            JevLog.write("[jev] typed \(secret ? "<secret>" : "\(text.count) chars")\(field.map { " into \($0)" } ?? "") -> \(result.status.rawValue)")
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

            let payload: [String: Any] = [
                "global": store.globalMode.rawValue,
                "globalOptions": GlobalMode.allCases.map { ["id": $0.rawValue, "label": $0.explanation] },
                "entries": entries,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
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

        server.onHints {
            // Read the current set. Refreshing here meant every read produced
            // a new numbering, so the numbers on the phone could differ from
            // the ones the Mac would act on.
            let data = (try? JSONEncoder().encode(Hints.shared.all)) ?? Data("[]".utf8)
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        server.onControls {
            // Include the window frame and each control's position relative to
            // it. Region detection is pure geometry, so it can only be tuned
            // against real numbers from real windows.
            let controls = JevIntent.frontmostControls(limit: 200)
            let window = HintScope.frontmostWindowFrame() ?? .zero
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

            let rows = controls.map { c -> [String: Any] in
                [
                    "label": c.label, "role": c.role,
                    "x": c.x, "y": c.y, "w": c.width, "h": c.height,
                    "rx": window.width > 0 ? (c.x - window.minX) / window.width : 0,
                    "ry": window.height > 0 ? (c.y - window.minY) / window.height : 0,
                    "rw": window.width > 0 ? c.width / window.width : 0,
                    "rh": window.height > 0 ? c.height / window.height : 0,
                ]
            }
            let payload: [String: Any] = [
                "app": app,
                "window": ["x": window.minX, "y": window.minY,
                           "w": window.width, "h": window.height],
                "controls": rows,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        server.onHandoff { _ in
            guard let host = Self.tailnetAddress() else { return nil }
            return "vnc://\(host)"
        }

        server.onWebSocketConnect { [weak self] session in
            guard let self else { return }
            Task { await self.addSocket(session) }
        }
    }

    /// Apply the saved mode for this app, if any, before troubling the human.
    private func dispatch(_ parsed: VoiceCommand.Parsed, spokenAs text: String) async -> ExecutionResult {
        guard let bundleId = parsed.command.bundleIdentifier else {
            return await requestApproval(for: parsed, spokenAs: text)
        }

        switch AppPolicyStore.shared.effectiveMode(for: bundleId) {
        case .always:
            let result = await executor.execute(parsed.command)
            // Report what actually happened. Substituting the description here
            // hid real failures behind a cheerful "Toggle Waz".
            return result

        case .never:
            JevLog.write("[jev] refused (never): \(parsed.description)")
            return .failed(reason: "\(parsed.description) is set to never allow")

        case .auto:
            return await autoDecide(parsed, spokenAs: text, bundleId: bundleId)

        case .none:
            return await requestApproval(for: parsed, spokenAs: text)
        }
    }

    /// Hand the request to the decision model.
    ///
    /// The question is deliberately narrow. An earlier version offered "ask the
    /// human" as one of the choices and invited Jev to pick it whenever a
    /// person's judgement might help — so it deferred on everything, including
    /// "scroll down", and auto was indistinguishable from ask. Asking instead
    /// whether the action is routine and reversible gives usable signal.
    private func autoDecide(_ parsed: VoiceCommand.Parsed, spokenAs text: String, bundleId: String) async -> ExecutionResult {
        guard let apiKey = JevAPI.loadAPIKey() else {
            return await requestApproval(for: parsed, spokenAs: text)
        }

        let appName = AppCatalog.shared.all.first { $0.bundleIdentifier == bundleId }?.name ?? bundleId
        let state: [String: Any] = [
            "spoken_request": text,
            "interpreted_as": parsed.description,
            "target": appName,
            "already_allowed": Array(AppPolicyStore.shared.all.filter { $0.value == .always }.keys),
            "explicitly_blocked": Array(AppPolicyStore.shared.all.filter { $0.value == .never }.keys),
        ]

        let questions: [String: JevAPI.Question] = [
            "routine": .noul(
                instructions: "A Mac assistant has been asked to do this by its owner. Is it a routine, low-risk, easily reversible action that the assistant should simply carry out?"
            ),
            "destructive": .noul(
                instructions: "Could this destroy data, send a message, spend money, change a security setting, or otherwise be hard to undo?"
            ),
        ]

        let result = await JevAPI.ask(state: state, questions: questions, apiKey: apiKey)
        guard case .success(let answers) = result else {
            JevLog.write("[jev] auto: Jev unavailable, asking you")
            return await requestApproval(for: parsed, spokenAs: text)
        }

        let routine = answers.noul("routine") ?? 0
        let destructive = answers.noul("destructive") ?? 1
        JevLog.write(String(format: "[jev] auto: %@ routine=%.2f destructive=%.2f",
                            parsed.description, routine, destructive))

        // Run it when Jev thinks it is routine and not destructive. Either
        // doubt goes to you: the asymmetry is the whole safety argument.
        guard routine >= 0.6, destructive <= 0.4 else {
            return await requestApproval(for: parsed, spokenAs: text)
        }

        let executed = await executor.execute(parsed.command, humanApproved: true)
        return executed.status == .ok
            ? .ok(reason: parsed.description)
            : executed
    }

    /// Park a command and put an approval in front of the human.
    private func requestApproval(for parsed: VoiceCommand.Parsed, spokenAs text: String) async -> ExecutionResult {
        let id = UUID().uuidString
        let friendly: [String: String] = [
            "system.gesture": "scrolling",
            "system.workspace": "workspace switching",
            "system.pointer": "clicking on screen",
            "system.keyboard": "typing",
        ]
        let appName = parsed.command.bundleIdentifier.flatMap { bundleId in
            friendly[bundleId] ?? AppCatalog.shared.all.first { $0.bundleIdentifier == bundleId }?.name
        } ?? "this app"

        let request = ApprovalRequest(
            id: id,
            kind: .spokenCommand,
            title: parsed.description,
            bodyText: "You said “\(text)”.\njev can do this, but \(appName) has not been allowed yet.",
            options: [
                ApprovalOption(id: "once", label: "Allow", riskLevel: .low),
                ApprovalOption(id: "deny", label: "Deny", riskLevel: .low),
            ],
            originatingApp: ApplicationInfo(
                name: appName,
                bundleIdentifier: parsed.command.bundleIdentifier ?? "unknown"
            ),
            timestamp: Date(),
            screenshotReference: nil,
            handoffOnly: false
        )

        pendingCommands[id] = parsed.command
        guard await store.addDeduplicated(request) else {
            JevLog.write("[jev] duplicate approval suppressed: \(parsed.description)")
            return .ok(reason: "Already waiting for your answer on that")
        }
        await broadcast(event: "approval", request: request)
        JevLog.write("[jev] asking for approval: \(parsed.description)")
        return .ok(reason: "Needs your approval — check the Approvals tab")
    }

    /// Answer a parked command. Returns nil when the id is not one of ours.
    func resolveCommandApproval(id: String, optionId: String) async -> ExecutionResult? {
        guard let command = pendingCommands[id] else { return nil }
        pendingCommands.removeValue(forKey: id)

        let bundleId = command.bundleIdentifier

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
        default:
            break
        }

        let result = await executor.execute(command, humanApproved: true)
        JevLog.write("[jev] approved (\(optionId)) -> \(result.status.rawValue): \(result.reason)")
        return result
    }

    /// Announce that an approval is no longer pending.
    private func setHintMode(_ mode: String) { hintMode = mode }

    /// Outline exactly one number, leaving the rest as bare digits.
    private func broadcastSingleBox(_ number: Int) async {
        let message = #"{"type":"hintBox","number":\#(number)}"#
        for socket in pruneSockets() { await socket.send(text: message) }
    }

    private func broadcastResolved(id: String) async {
        let message = #"{"type":"resolved","id":"\#(id)"}"#
        for socket in pruneSockets() {
            await socket.send(text: message)
        }
    }

    private func broadcastHints() async {
        let hints = Hints.shared.all
        guard let data = try? JSONEncoder().encode(hints),
              let json = String(data: data, encoding: .utf8) else { return }
        let message = #"{"type":"hints","mode":"\#(hintMode)","hints":\#(json)}"#
        JevLog.write("[jev] broadcasting \(hints.count) hints (\(hintMode)) to \(sockets.count) socket(s)")
        for socket in pruneSockets() { await socket.send(text: message) }
    }

    private func broadcastHintsCleared() async {
        for socket in pruneSockets() { await socket.send(text: #"{"type":"hints","hints":[]}"#) }
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

    /// Show a scanned form on the phone.
    func broadcastForm(_ fields: [FormScanner.Field]) async {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(fields),
              let list = String(data: data, encoding: .utf8) else { return }
        let json = #"{"type":"form","fields":\#(list)}"#
        for socket in pruneSockets() { await socket.send(text: json) }
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
            try? Data(text.utf8).write(to: file)
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
