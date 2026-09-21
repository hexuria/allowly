// Surface failures on the page. A silent exception in init leaves the UI
// looking merely broken — black screen, placeholder text — with no clue why,
// and there is no console to open on a phone.
window.addEventListener('error', (e) => {
    const el = document.getElementById('screenStatus');
    if (el) el.textContent = `JS error: ${e.message} (${(e.filename || '').split('/').pop()}:${e.lineno})`;
});
window.addEventListener('unhandledrejection', (e) => {
    const el = document.getElementById('screenStatus');
    if (el) el.textContent = `Failed: ${e.reason && e.reason.message ? e.reason.message : e.reason}`;
});

const APP = {
    baseUrl: null,
    token: null,
    ws: null,
    screenTimer: null,
    handsFree: null,
    screenScale: 1,
    zoomOriginX: 50,
    zoomOriginY: 50,
    screenNudge: null,
    screenTick: null,
    screenWatchdog: null,
    lastFrameTry: 0,
    sheetApproval: null,
    state: {
        connected: false,
        approvals: new Map(),
        recording: false,
        recordingStartTime: null,
        mediaRecorder: null,
        audioChunks: [],
    },

    // Initialize app on page load
    init() {
        this.migrateStorage();
        this.restoreSession();
        this.setupEventListeners();
        this.detectPlatform();

        // Pinch belongs to the Mac's picture, not to this page.
        //
        // iOS Safari has ignored user-scalable=no since iOS 10, so a pinch
        // anywhere zoomed the whole PWA — the same gesture, fighting the one
        // that zooms the screen view, which is why zooming felt broken.
        // Safari fires its own gesture* events for page pinch; refusing them
        // is the only thing that actually stops it. Nothing in this app wants
        // browser zoom: the text is already sized for a phone and the one
        // thing worth magnifying has its own zoom.
        ['gesturestart', 'gesturechange', 'gestureend'].forEach(type => {
            document.addEventListener(type, (e) => e.preventDefault(), { passive: false });
        });
        // And the other way in: double-tap to zoom. Two taps under 300ms
        // apart anywhere outside a control.
        let lastTouchEnd = 0;
        document.addEventListener('touchend', (e) => {
            const now = Date.now();
            if (now - lastTouchEnd < 300 && !e.target.closest('input, select, textarea, button')) {
                e.preventDefault();
            }
            lastTouchEnd = now;
        }, { passive: false });

        // Once now (in case layout is already settled) and again after the
        // first frame and after load — at DOMContentLoaded the stylesheet may
        // not have been applied yet and the header measures 0.
        this.measureHeader();
        requestAnimationFrame(() => this.measureHeader());
        window.addEventListener('load', () => this.measureHeader());
        window.addEventListener('resize', () => this.measureHeader());
        window.addEventListener('orientationchange', () => setTimeout(() => this.measureHeader(), 200));

        if (this.baseUrl && this.token) {
            this.startFromPaired();
        } else {
            this.showSetupScreen();
        }
    },

    // Notifications are the whole point of the product when the phone is in a
    // pocket, so the app asks for them rather than hiding a toggle in settings.
    // iOS only delivers web push to an installed PWA — an Apple rule, not a
    // setting — so an uninstalled iPhone gets told to install first.
    detectPlatform() {
        const banner = document.getElementById('pushBanner');
        const action = document.getElementById('pushBannerAction');
        if (!banner) return;

        const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
        const supported = 'serviceWorker' in navigator && 'PushManager' in window;
        const show = (message, actionLabel) => this.showPushBanner(message, actionLabel);

        if (localStorage.getItem('allowly-push-dismissed') === 'true') return;

        if (isIOS && !this.isInstalled()) {
            show('Add Allowly to your Home Screen so approvals can reach you when the app is closed.');
            return;
        }
        if (!supported) return;
        if (Notification.permission === 'granted') {
            this.ensurePushSubscription();
            return;
        }
        if (Notification.permission === 'denied') {
            show('Notifications are blocked. Approvals will only appear while Allowly is open.');
            return;
        }
        show('Get told when something needs your approval.', 'Turn on');
        action.onclick = async () => {
            // Must run inside the gesture — iOS ignores a deferred request.
            const permission = await Notification.requestPermission();
            if (permission !== 'granted') {
                show('Notifications are blocked. Approvals will only appear while Allowly is open.');
                return;
            }
            banner.classList.add('hidden');
            this.ensurePushSubscription();
        };
    },

    // A short confirmation. Answering an approval made the card vanish with
    // nothing said, so a sent decision looked exactly like a dropped tap.
    // This also replaces alert(), which on a phone blocks the whole page and
    // looks like the browser, not like the app.
    // What jev is doing in the browser, step by step.
    //
    // A web task runs in a tab nobody is watching and changes nothing on the
    // Mac's screen, so without this the phone sits silent for a minute with
    // no reason to believe anything is happening. Retries are shown rather
    // than hidden: if jev had to try a step twice, that is what it did.
    showWebProgress(message) {
        const bar = document.getElementById('webProgress');
        const text = document.getElementById('webProgressText');
        if (!bar || !text) return;

        clearTimeout(this.webProgressTimer);
        if (message.finished) {
            bar.hidden = true;
            text.textContent = '';
            return;
        }
        // A Mac that goes away mid-task never sends the finishing message, and
        // a spinner that spins forever is worse than no spinner. Longer than
        // the task budget, so it only fires when something really stopped.
        this.webProgressTimer = setTimeout(() => {
            bar.hidden = true;
            text.textContent = '';
        }, 120000);

        // Everything here came off a web page, so it is text and never markup.
        const operation = String(message.operation || '').toLowerCase().replace(/_/g, ' ');
        const target = String(message.target || '');
        const step = Number(message.step) || 0;
        const retry = message.retry ? ' again' : '';
        text.textContent = target
            ? `Step ${step}: ${operation}${retry} — ${target}`
            : `Step ${step}: ${operation}${retry}`;
        bar.hidden = false;
    },

    toast(message, bad) {
        const el = document.getElementById('toast');
        if (!el) return;
        // .shown, not .hidden: the element stays rendered so that its
        // aria-live region is already in the accessibility tree when the text
        // changes. display:none and visibility:hidden both take it out, and a
        // live region that is not in the tree is never announced.
        el.textContent = message;
        el.classList.toggle('bad', !!bad);
        el.classList.add('shown');
        clearTimeout(this.toastTimer);
        clearTimeout(this.toastClear);
        this.toastTimer = setTimeout(() => {
            el.classList.remove('shown');
            // Empty it once faded, so a stale message cannot be read back.
            this.toastClear = setTimeout(() => { el.textContent = ''; }, 200);
        }, bad ? 4000 : 2000);
    },

    /// The notifications row in Settings.
    ///
    /// Exists so that "Not now" is a choice rather than a trapdoor.
    renderPushSetting() {
        const row = document.getElementById('pushSetting');
        const button = document.getElementById('pushEnable');
        if (!row || !button) return;
        let state = 'Notifications are on.';
        let canEnable = false;
        try {
            if (!('Notification' in window)) {
                state = 'This browser cannot show notifications.';
            } else if (Notification.permission === 'denied') {
                state = 'Notifications are blocked in your browser settings.';
            } else if (localStorage.getItem('allowly-push-dismissed') === 'true') {
                state = 'You chose not to be notified on this phone.';
                canEnable = true;
            } else if (Notification.permission !== 'granted') {
                state = 'Notifications are not set up on this phone.';
                canEnable = true;
            } else if (this.pushSubscribed === false) {
                // Allowed here, not working there. Two different facts,
                // and this row used to report only the first while
                // claiming the second.
                state = 'Allowed on this phone, but your Mac has not accepted them'
                    + (this.pushBlocked ? ` — ${this.pushBlocked}.` : '.');
                canEnable = true;
            } else if (this.pushSubscribed === null) {
                state = 'Allowed on this phone — not confirmed with your Mac yet.';
                canEnable = true;
            }
        } catch (err) {
            state = 'Notifications are not set up on this phone.';
            canEnable = true;
        }
        document.getElementById('pushSettingState').textContent = state;
        button.classList.toggle('hidden', !canEnable);
    },

    // Push problems are invisible by nature — nothing arrives and no error is
    // shown anywhere — so they go on screen.
    showPushBanner(message, actionLabel) {
        const banner = document.getElementById('pushBanner');
        const text = document.getElementById('pushBannerText');
        const action = document.getElementById('pushBannerAction');
        if (!banner) return;
        text.textContent = message;
        action.classList.toggle('hidden', !actionLabel);
        if (actionLabel) action.textContent = actionLabel;
        banner.classList.remove('hidden');
    },

    // Re-registers on every launch. The push service can rotate an endpoint at
    // any time, and the Mac stores subscriptions by endpoint, so this is a
    // cheap upsert rather than a duplicate.
    /// Ask the Mac whether its last notification actually arrived.
    ///
    /// The push-failure banner was painted only from `renderPolicy`,
    /// which only runs when the settings sheet is opened — so the one
    /// warning that notifications are dead was behind two taps, and was
    /// covered by the sheet at the moment it appeared. Someone who never
    /// opens Settings never saw it.
    async checkPushHealth() {
        if (!this.baseUrl || !this.token) return;
        const era = this.era();
        try {
            const response = await fetch(`${this.baseUrl}/api/policy`, {
                headers: { 'Authorization': `Bearer ${this.token}` },
            });
            const policy = await response.json();
            if (!this.sameEra(era)) return;
            if (policy && policy.pushError) {
                this.showPushBanner(`Notifications are not arriving: ${policy.pushError}`);
            }
        } catch (err) {
            // A Mac we cannot reach is already reported elsewhere.
        }
    },

    /// Whether the Mac has actually accepted a subscription from this
    /// phone. `null` until something has tried.
    ///
    /// Settings used to decide what to say purely from
    /// `Notification.permission`, which answers a different question:
    /// the phone allowing notifications says nothing about whether the
    /// Mac can send any. Measured — with the Mac returning 500 from
    /// `/api/subscribe`, and again with the service worker missing —
    /// the row read "Notifications are on." both times. That is the one
    /// screen that could have told the truth saying the opposite of it.
    pushSubscribed: null,
    pushBlocked: null,

    async ensurePushSubscription() {
        const fail = (why) => {
            this.pushSubscribed = false;
            this.pushBlocked = why;
            return false;
        };
        // Truthiness, not just presence: a browser can expose the key
        // and leave it null, and the raw TypeError from `.ready` then
        // became the explanation shown to the person.
        if (!navigator.serviceWorker || !('PushManager' in window)) {
            return fail('this browser cannot receive them');
        }
        if (typeof Notification === 'undefined' || Notification.permission !== 'granted') {
            return fail('permission has not been given on this phone');
        }
        if (!this.token || !this.baseUrl) return fail('this phone is not paired yet');
        try {
            // Bounded. `serviceWorker.ready` can simply never settle, and
            // when it did not, the caller's `finally` never ran either —
            // so the row kept whatever it said before and the button sat
            // there looking untapped.
            const registration = await Promise.race([
                navigator.serviceWorker.ready,
                new Promise((_, reject) =>
                    setTimeout(() => reject(new Error('the service worker never became ready')), 10000)),
            ]);
            const subscription = await this.subscribeToPush(registration);
            if (!subscription) return fail('your Mac did not accept the subscription');
            this.pushSubscribed = true;
            this.pushBlocked = null;
            return true;
        } catch (error) {
            console.error('Push subscription failed:', error);
            return fail(error.message || 'it did not work');
        }
    },

    isInstalled() {
        return window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
    },

    // Restore session from localStorage, or pair straight from the URL.

    migrateStorage() {
        const pairs = [
            ['jev-session', 'allowly-session'],
            ['jev-push-dismissed', 'allowly-push-dismissed'],
            ['jev-hands-free', 'allowly-hands-free'],
            ['jev-fullscreen-hint', 'allowly-fullscreen-hint'],
            ['jev-screen-fill', 'allowly-screen-fill'],
        ];
        for (const [from, to] of pairs) {
            if (localStorage.getItem(to) === null && localStorage.getItem(from) !== null) {
                localStorage.setItem(to, localStorage.getItem(from));
            }
        }
    },

    restoreSession() {
        try {
            const stored = localStorage.getItem('allowly-session');
            if (stored) {
                const session = JSON.parse(stored);
                this.baseUrl = session.baseUrl;
                this.token = session.token;
            }
        } catch (e) {
            console.error('Failed to restore session:', e);
        }

        // Pair from ?token=… so opening the link the Mac prints is all it takes.
        // The token is then dropped from the address bar so it does not linger
        // in history or get shared along with the page.
        // Read both out of the query BEFORE anything rewrites it: the
        // pairing branch below clears the whole search string, so a link
        // carrying both would have lost the approval id.
        let wantedApproval = null;
        try {
            wantedApproval = new URLSearchParams(window.location.search).get('approval');
        } catch (e) { /* the card list still works without it */ }

        try {
            const fromUrl = new URLSearchParams(window.location.search).get('token');
            if (fromUrl) {
                this.baseUrl = window.location.origin;
                this.token = fromUrl;
                this.saveSession();
                window.history.replaceState({}, '', window.location.pathname);
            }
        } catch (e) {
            console.error('Failed to pair from URL:', e);
        }

        // Which card the notification was about.
        //
        // `escalate` has always pushed "/?approval=<id>" and the service
        // worker has always forwarded it, and nothing at this end ever
        // read either one. So tapping a notification about a Claude Code
        // prompt opened the app showing the OLDEST card — a Chrome sheet
        // from thirty seconds earlier — with "1 more after this"
        // underneath. A reflexive Allow answered the wrong request. Same
        // failure as answering by voice, through the notification door.
        if (wantedApproval) {
            this.focusApproval = wantedApproval;
            try { window.history.replaceState({}, '', window.location.pathname); } catch (e) {}
        }

        try {
            navigator.serviceWorker && navigator.serviceWorker.addEventListener('message', (event) => {
                if (!event.data || event.data.type !== 'approval-notification') return;
                try {
                    const id = new URL(event.data.url).searchParams.get('approval');
                    if (id) { this.focusApproval = id; this.loadApprovals(); }
                } catch (e) { /* a malformed url is not worth a crash */ }
            });
        } catch (e) { /* no service worker, no handoff */ }
    },

    // Save session to localStorage
    saveSession() {
        localStorage.setItem('allowly-session', JSON.stringify({
            baseUrl: this.baseUrl,
            token: this.token,
        }));
    },

    // Setup event listeners
    setupEventListeners() {
        // Setup screen
        document.getElementById('connectBtn').addEventListener('click', () => this.handlePairing());
        document.getElementById('pairingUrl').addEventListener('keypress', (e) => {
            if (e.key === 'Enter') this.handlePairing();
        });

        document.getElementById('settingsBtn')?.addEventListener('click', () => this.openSheet('settingsSheet'));
        document.getElementById('inputBtn')?.addEventListener('click', () => this.openSheet('inputSheet'));
        document.querySelectorAll('[data-close]').forEach(el => {
            el.addEventListener('click', () => this.closeSheet(el.dataset.close));
        });
        document.getElementById('changePairingBtn').addEventListener('click', () => this.changePairing());


        document.getElementById('pushBannerDismiss')?.addEventListener('click', () => {
            document.getElementById('pushBanner').classList.add('hidden');
            localStorage.setItem('allowly-push-dismissed', 'true');
            this.renderPushSetting();
        });

        // …and a way back. Nothing anywhere cleared that flag, so one
        // tap of "Not now" meant this phone never asked about
        // notifications again and could not be made to, short of
        // clearing the site data — on the feature the product is built
        // around.
        //
        // `detectPlatform`, not `checkPushSupport` — there is no such
        // function, so this handler threw a TypeError on its third line
        // and `ensurePushSubscription` below it never ran. The button
        // cleared the flag, repainted the row, and did nothing else: no
        // permission prompt, no subscription, and on a phone that had
        // already granted permission the row then claimed
        // "Notifications are on." while the Mac had never been told.
        // The one escape hatch from "Not now" was itself broken.
        document.getElementById('pushEnable')?.addEventListener('click', async () => {
            localStorage.removeItem('allowly-push-dismissed');
            // ASK. Round 29 fixed the TypeError here and left the button
            // a no-op in the state it exists for: `detectPlatform` only
            // paints a banner, and `ensurePushSubscription` returns at
            // its own `permission !== 'granted'` guard — so tapping
            // "Turn notifications on" produced no iOS permission sheet,
            // no subscription, and a row whose wording changed as if
            // something had happened. The click is itself the user
            // gesture iOS requires, so this is the one place that can
            // legitimately prompt.
            try {
                if (typeof Notification !== 'undefined'
                    && Notification.permission === 'default') {
                    await Notification.requestPermission();
                }
                if (typeof Notification !== 'undefined'
                    && Notification.permission === 'granted') {
                    const ok = await this.ensurePushSubscription();
                    // Said out loud, above the sheet. The banner this
                    // would otherwise paint lives inside the main
                    // screen, underneath the sheet the person is
                    // looking at; the toast is at z-index 600 and the
                    // sheet is at 400.
                    if (!ok) {
                        this.toast(`Notifications are still off — ${this.pushBlocked}`, true);
                    }
                } else {
                    // Refused at the system prompt: say so where they
                    // are looking, rather than leaving the row to imply
                    // it worked.
                    this.detectPlatform();
                }
            } catch (err) {
                console.error('Could not turn notifications on:', err);
            } finally {
                this.renderPushSetting();
            }
        });

        // Modal overlay close
        document.querySelectorAll('.modal-overlay').forEach(overlay => {
            overlay.addEventListener('click', (e) => {
                if (e.target === overlay) {
                    this.closeAllModals();
                }
            });
        });

        // Push-to-talk
        const pttBtn = document.getElementById('pttBtn');
        pttBtn.addEventListener('mousedown', () => this.startRecording());
        pttBtn.addEventListener('touchstart', (e) => {
            e.preventDefault();
            this.startRecording();
        }, { passive: false });

        pttBtn.addEventListener('mouseup', () => this.stopRecording());
        pttBtn.addEventListener('touchend', (e) => {
            e.preventDefault();
            this.stopRecording();
        }, { passive: false });

        pttBtn.addEventListener('mouseleave', () => {
            if (this.state.recording) this.stopRecording();
        });

        // Tabs
        document.getElementById('handsFree')?.addEventListener('change', (e) => {
            if (e.target.checked) this.startHandsFree(); else this.stopHandsFree();
        });
        // No Click / Double / Right-click buttons: say it instead. The
        // Phrasebook already knows "click this", "double click this" and
        // "right click this", and four controls on screen for something
        // voice already does is clutter.

        // Full screen. Not the Fullscreen API: iOS Safari refuses it for
        // anything but a <video>, so the stage is lifted to cover the
        // viewport in CSS instead, which also keeps the approval layer on top.
        document.getElementById('fullscreenBtn')?.addEventListener('click', () => this.setFullscreen(true));
        document.getElementById('exitFullscreenBtn')?.addEventListener('click', () => this.setFullscreen(false));
        document.getElementById('fillToggle')?.addEventListener('click', () => this.toggleScreenFill());
        document.getElementById('numbersBtn')?.addEventListener('click', () => this.toggleNumbers());
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && document.body.classList.contains('fullscreen')) this.setFullscreen(false);
        });

        document.getElementById('typeSend')?.addEventListener('click', () => this.sendTypedText());
        document.getElementById('typeSecret')?.addEventListener('change', (e) => {
            document.getElementById('typeText').type = e.target.checked ? 'password' : 'text';
        });
        document.getElementById('typeText')?.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') this.sendTypedText();
        });

        document.querySelectorAll('#approvalSheet .sheet-action[data-mode]').forEach(btn => {
            btn.addEventListener('click', () => this.applyRememberedChoice(btn.dataset.mode));
        });

        document.getElementById('policyReset')?.addEventListener('click', () => {
            this.setPolicy({ reset: true });
        });

        // Stop pulling frames when the app is backgrounded.
        document.addEventListener('visibilitychange', () => {
            if (document.hidden) {
                this.stopScreenPolling();
                // iOS suspends capture when backgrounded; the graph has to be
                // rebuilt rather than resumed.
                if (this.handsFree) {
                    this.handsFree.stream.getTracks().forEach(t => t.stop());
                    this.handsFree.context.close().catch(() => {});
                    this.handsFree = null;
                    this.setHandsFreeStatus('Paused — tap to resume', '');
                }
            }
            else {
                if (this.baseUrl && this.token) this.startScreenPolling();
                // Re-ask what is actually waiting.
                //
                // `resolved` arrives over the websocket, and a phone that
                // was asleep or out of Tailscale range misses it — so the
                // card on screen can be one the Mac answered, withdrew or
                // forgot minutes ago. Coming back to the app is the natural
                // moment to find out, and it costs one small request.
                if (this.baseUrl && this.token) this.loadApprovals();
                if (localStorage.getItem('allowly-hands-free') === 'true' && !this.handsFree) {
                    this.startHandsFree();
                }
            }
        });

        // Confirmation modal
        document.getElementById('confirmCancel').addEventListener('click', () => this.closeConfirm());
        document.getElementById('confirmYes').addEventListener('click', () => this.submitConfirmedDecision());
    },

    // Pairing
    handlePairing() {
        const url = document.getElementById('pairingUrl').value.trim();
        if (!url) {
            this.toast('Paste the pairing link first', true);
            return;
        }

        try {
            const parsed = new URL(url);
            const token = parsed.searchParams.get('token');

            if (!token) {
                this.toast('That link has no token in it', true);
                return;
            }

            // The link has to be for the Mac this app came FROM.
            //
            // jev serves no CORS headers and does not answer OPTIONS —
            // deliberately, because widening a daemon that drives the
            // mouse to accept cross-origin calls is not a trade worth
            // making for a paste box. So pasting a second Mac's link
            // into an app installed from the first produced something
            // worse than a refusal: the websocket authenticates by
            // query parameter and is not CORS-restricted, so the pill
            // read "Connected" while every single HTTP call failed the
            // preflight — no screen, no cards, no taps, no voice, and
            // no way to diagnose it from inside an installed PWA with
            // no address bar.
            //
            // Opening the link is the supported path, and it works,
            // because it loads that Mac's own copy of the app.
            if (parsed.origin !== window.location.origin) {
                this.toast(`That link is for ${parsed.host}; this app came from ${window.location.host}.`
                    + ' Open the link instead — it installs that Mac’s own app.', true);
                return;
            }

            // No trailing slash. `pairingURL` ends in "/?token=…", so
            // splitting on "?" left "https://host/" and every single
            // request the app made went to "https://host//api/…" — a
            // path the Mac's auth check did not recognise as an API
            // route while its router happily served it. Fixed at both
            // ends; this is the end that stops producing it.
            // The ORIGIN, like the ?token= bootstrap uses. Keeping the
            // pasted path meant "https://mac/index.html?token=…" set a
            // baseUrl of ".../index.html" and every API call 404'd.
            // Now that the origin has to match, `parsed.origin` and
            // `window.location.origin` are the same thing.
            this.baseUrl = parsed.origin;
            this.token = token;
            this.saveSession();
            this.startFromPaired();
        } catch (e) {
            this.toast('That does not look like a link', true);
        }
    },

    // Everything that has to happen once there is a Mac to talk to.
    //
    // Pairing by PASTE used to do only two of these, so the main screen
    // appeared, approvals arrived, and nothing else worked: "Your Mac"
    // was a blank image because the poll never started, pinch and scroll
    // and the pointer were unwired because `startScreenPolling` is the
    // only thing that installs them, and no push subscription was ever
    // registered because that had already bailed at startup on a missing
    // token — so no notification would ever arrive. It all silently
    // healed on the next reload, which is why it read as flaky rather
    // than broken.
    startFromPaired() {
        this.showMainScreen();
        this.startScreenPolling();
        this.connectWebSocket();
        this.ensurePushSubscription();
        // Ask once, on every launch, whether the Mac's last notification
        // got through — see `checkPushHealth`.
        this.checkPushHealth();
        // Hands-free too, or the toggle reads "on" while nothing is
        // listening — reachable by unpairing and re-pairing, since the
        // preference outlives the session.
        if (localStorage.getItem('allowly-hands-free') === 'true') {
            this.syncHandsFreeToggles(true);
            this.setHandsFreeStatus('Tap anywhere to start listening', '');
            // iOS will not open a microphone without a user gesture, so
            // it cannot simply resume — one tap arms it again.
            const arm = () => {
                document.removeEventListener('touchend', arm);
                document.removeEventListener('click', arm);
                this.startHandsFree();
            };
            document.addEventListener('touchend', arm, { once: true });
            document.addEventListener('click', arm, { once: true });
        }
    },

    changePairing() {
        this.closeConfirm();
        // ALL of them. The sheets are siblings of #mainScreen, not
        // children, so hiding the main screen leaves them on top of the
        // setup screen — a half-typed password still in the DOM, with
        // its Send button live.
        ['approvalSheet', 'formSheet', 'inputSheet', 'settingsSheet'].forEach(id => this.closeSheet(id));
        this.spec = null;
        this.specState = null;
        this.specFields = null;
        this.focusedField = null;
        // The DOM those sheets left behind, too. `closeSheet` only adds
        // `.hidden`: the policy rows kept live handlers, the type box
        // kept whatever was typed into it — a password, on the sheet
        // whose whole purpose is passwords — and the transcript list
        // kept what was said to the previous Mac.
        ['policyEntries', 'voiceHistory', 'numbersLayer', 'formFields'].forEach(id => {
            const el = document.getElementById(id);
            if (el) el.innerHTML = '';
        });
        const typed = document.getElementById('typeText');
        if (typed) typed.value = '';
        // `typeField`, not `typeFieldName`. The guarded lookup meant the
        // wrong id failed silently: the field NAME survived an unpair,
        // so typing into the sheet on a second Mac sent the text to
        // whatever box the first Mac's form had been asking about —
        // "password", if that is what you had filled in.
        const typedField = document.getElementById('typeField');
        if (typedField) typedField.value = '';
        this.baseUrl = null;
        this.token = null;
        // A card from the Mac you just unpaired from is not a card —
        // and clearing the Map is not enough on its own, because
        // nothing redraws. The old Mac's card stayed in the DOM with
        // live buttons, so pairing with a second Mac showed the first
        // one's prompt and a tap posted a decision for an id it had
        // never heard of. Same for the last JPEG, which the poll went
        // on refreshing against a baseUrl that is now null.
        this.focusApproval = null;
        this.confirmData = null;
        this.sheetApproval = null;
        this.state.approvals.clear();
        this.renderApprovals();
        this.stopScreenPolling();
        const shot = document.getElementById('screenImage');
        if (shot) shot.removeAttribute('src');
        // The microphone, too. Nothing here touched `handsFree`, so an
        // already-running session went on cutting segments and POSTing
        // them to "null/api/voice" — which resolves RELATIVE to the
        // page, so the audio kept going to the Mac you just unpaired
        // from. And the tap on "Pair with a different Mac" bubbles to
        // the document, where the one-shot arm listener was still
        // waiting: unpairing could TURN THE MICROPHONE ON.
        this.hideNumbers();
        this.stopHandsFree();
        // Cancel the push subscription, or the Mac you just left goes on
        // notifying you — and tapping one of ITS notifications opens the
        // app, fails to find that card in the NEW Mac's list, and falls
        // through to whatever the new Mac happens to have waiting. You
        // tapped a camera prompt and are one reflex from approving a
        // shell command on a different machine. That is the exact harm
        // the notification-to-card plumbing was written to prevent.
        this.unsubscribeFromPush();
        // The subscription is being revoked, so nothing is known about
        // the next one. Left as-is, Settings kept saying "Notifications
        // are on." about a subscription this line just tore down.
        this.pushSubscribed = null;
        this.pushBlocked = null;
        localStorage.removeItem('allowly-hands-free');
        this.syncHandsFreeToggles(false);
        // Anything already in flight must not repopulate what this just
        // cleared. An /api/pending response landing after the clear put
        // the old Mac's card back, with live buttons.
        this.pairingGeneration = (this.pairingGeneration || 0) + 1;
        this.approvalsLoaded = false;
        localStorage.removeItem('allowly-session');
        this.disconnectWebSocket();
        this.showSetupScreen();
        this.closeSettings();
    },

    // Screen transitions
    showSetupScreen() {
        document.getElementById('setupScreen').classList.remove('hidden');
        document.getElementById('mainScreen').classList.add('hidden');
    },

    showMainScreen() {
        document.getElementById('setupScreen').classList.add('hidden');
        document.getElementById('mainScreen').classList.remove('hidden');
        // The header only has a height once this screen is up.
        requestAnimationFrame(() => this.measureHeader());
        document.getElementById('currentUrl').value = this.baseUrl || '';
    },

    // WebSocket connection
    connectWebSocket() {
        // Nothing to connect to. `disconnectWebSocket` cannot stop the
        // close handler that is already in flight, and that handler
        // schedules a retry two seconds out — which then dereferenced a
        // null baseUrl and painted a JS error across the screen status
        // line, visible the next time the main screen appeared.
        if (!this.baseUrl || !this.token) return;
        if (this.ws) return;

        const wsProtocol = this.baseUrl.startsWith('https') ? 'wss' : 'ws';
        const wsUrl = `${wsProtocol}://${new URL(this.baseUrl).hostname}:${new URL(this.baseUrl).port || (wsProtocol === 'wss' ? 443 : 80)}/ws?token=${this.token}`;

        try {
            this.ws = new WebSocket(wsUrl);

            this.ws.addEventListener('open', () => {
                this.setConnectionStatus(true);
                // Pull whatever is already waiting. Relying only on live pushes
                // meant anything raised before this tab connected — or while it
                // was closed — never appeared at all.
                this.loadApprovals();
            });

            this.ws.addEventListener('message', (event) => {
                this.handleWebSocketMessage(event.data);
            });

            // Capture the socket this listener belongs to. Nulling
            // `this.ws` unconditionally could clear the reference to a
            // NEWER socket — an unpair and re-pair inside the closing
            // handshake — after which the retry two seconds later sees
            // null, opens a second one, and every approval push is
            // handled twice while `disconnectWebSocket` can only ever
            // close one of them.
            const socket = this.ws;
            socket.addEventListener('error', (error) => {
                console.error('WebSocket error:', error);
                // Scoped like `close` below. Unscoped, an error from the
                // PREVIOUS socket could mark a live connection dead
                // after a re-pair with nothing left to set it true
                // again — the same failure, one listener over.
                if (this.ws !== null && this.ws !== socket) return;
                this.setConnectionStatus(false);
            });

            socket.addEventListener('close', () => {
                // Only when this socket is still the one we are using,
                // OR there is none at all.
                //
                // Guarding after the status flip was the first attempt
                // and left `state.connected` true across an unpair;
                // flipping it unconditionally was the second and was
                // worse — a slow close from the PREVIOUS Mac could land
                // after the new socket was open and mark a live
                // connection dead for the rest of the session, with
                // nothing left to set it true again.
                if (this.ws !== null && this.ws !== socket) return;
                this.setConnectionStatus(false);
                if (this.ws !== socket) return;
                this.ws = null;
                // Attempt to reconnect after 2 seconds
                setTimeout(() => this.connectWebSocket(), 2000);
            });


        } catch (e) {
            console.error('Failed to create WebSocket:', e);
            this.setConnectionStatus(false);
        }
    },

    disconnectWebSocket() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
    },

    setConnectionStatus(connected) {
        this.state.connected = connected;
        const was = this.state.connectedShown;
        this.updateStatusPill();
        this.state.connectedShown = connected;

        // Full screen hides the header, and with it the only indication that
        // the Mac is still there — for everyone, not just screen readers. Say
        // it out loud instead, but only on the change, not every retry.
        if (!connected && was !== false && document.body.classList.contains('fullscreen')) {
            this.toast('Lost the Mac — still trying', true);
        }
    },

    handleWebSocketMessage(data) {
        // `ws.close()` cannot un-queue a message the browser has already
        // delivered, and there is no await here for the era rule to
        // straddle — so this is the one place it cannot reach. A
        // `resolved` or `approval` push arriving in the same turn as an
        // unpair would put the old Mac's card straight back on screen.
        if (!this.baseUrl || !this.token) return;
        try {
            const message = JSON.parse(data);

            if (message.type === 'approval') {
                this.handleNewApproval(message.approval);
            } else if (message.type === 'resolved') {
                this.handleResolvedApproval(message.id);
            } else if (message.type === 'needInput') {
                this.promptForInput(message.field, message.secret);
            } else if (message.type === 'numbers') {
                // Obey, do not toggle. "Show guides" used to hide them
                // whenever they were already up.
                if (message.show === false) this.hideNumbers();
                else this.showNumbers();
            } else if (message.type === 'spec') {
                this.showSpec(message.spec);
            } else if (message.type === 'webProgress') {
                this.showWebProgress(message);
            } else if (message.type === 'form') {
                // A Mac that has not been rebuilt yet still sends a flat
                // field list. Wrap it so there is only one renderer.
                this.showSpec(this.specFromFields(message.fields || []));
            }
        } catch (e) {
            console.error('Failed to parse WebSocket message:', e);
        }
    },

    // Tabs
    // Sheets replace the tab bar entirely: one screen, and options slide up
    // over it. Tabs were making you navigate away from the thing you are
    // watching in order to answer it.
    openSheet(id) {
        document.getElementById(id)?.classList.remove('hidden');
        if (id === 'settingsSheet') { this.loadPolicy(); this.renderPushSetting(); }
    },

    closeSheet(id) {
        document.getElementById(id)?.classList.add('hidden');
        // Whichever way it was dismissed, the question it was asking is
        // no longer being asked. Only the Cancel button was wired to
        // `closeConfirm`, so tapping the scrim left `confirmData`
        // armed — and the Mac withdrawing that request then toasted
        // "your Mac took that one back" about a modal you had already
        // dismissed yourself.
        if (id === 'confirmModal') { this.confirmData = null; this.pendingRemember = null; }
        if (id === 'approvalSheet') this.sheetApproval = null;
        if (id === 'inputSheet') this.resetInputSheet();
    },

    /// Put the type sheet back to a blank, non-secret, unaddressed state.
    ///
    /// Nothing cleared it on dismissal. The Mac asks for a password, you
    /// type it, you tap the scrim instead of Send — and the password
    /// stays in the DOM with `type=password` and the secret box ticked.
    /// Tap the Type button later and the sheet reopens still headed
    /// "Enter the password", still holding it, but now with no field
    /// name: "Send to Mac" would put it into whatever happens to be
    /// focused over there.
    ///
    /// It clears a half-typed ordinary message too. That costs a
    /// retype; the other way costs a password in the wrong box.
    resetInputSheet() {
        const textEl = document.getElementById('typeText');
        const fieldEl = document.getElementById('typeField');
        const secretEl = document.getElementById('typeSecret');
        const status = document.getElementById('typeStatus');
        const heading = document.querySelector('#inputSheet h2');
        if (textEl) { textEl.value = ''; textEl.type = 'text'; }
        if (fieldEl) fieldEl.value = '';
        if (secretEl) secretEl.checked = false;
        if (heading) heading.textContent = 'Type on the Mac';
        if (status) status.textContent = 'Goes wherever the pointer is on the Mac.';
    },

    // The notification layer hangs off the bottom of the header, whose height
    // moves with the safe-area inset and the text size, so it is measured
    // rather than guessed.
    measureHeader() {
        const header = document.querySelector('.header');
        if (!header) return;
        const h = header.offsetHeight;
        if (h > 0) document.documentElement.style.setProperty('--header-h', `${h}px`);
    },

    setFullscreen(on) {
        document.body.classList.toggle('fullscreen', !!on);
        const btn = document.getElementById('fullscreenBtn');
        if (btn) btn.setAttribute('aria-pressed', on ? 'true' : 'false');

        // A zoom left over from before would be scaled against a different
        // box, so the stage starts from 1:1 either way.
        this.setZoom(1);

        // Re-arm the timer: full screen polls at the faster cadence, because
        // the stream is now the whole point rather than a thumbnail.
        if (this.screenTimer) { this.stopScreenPolling(); this.startScreenPolling(); }
        if (on) document.getElementById('exitFullscreenBtn')?.focus();
        else btn?.focus();

        // Remember how the picture should be sized in full screen.
        this.applyScreenFill();

        // Safari's own bars are not ours to hide.
        //
        // In a tab, nothing a page can do removes the address bar and the tab
        // strip — iOS only grants real full screen to a <video>, which is how
        // YouTube manages it and why this looks broken next to it. Installed
        // to the home screen the app runs standalone and there is no browser
        // chrome at all. Said once, then remembered, because a nag every time
        // is worse than the problem.
        if (on && !this.isInstalled() && !localStorage.getItem('allowly-fullscreen-hint')) {
            localStorage.setItem('allowly-fullscreen-hint', '1');
            this.toast('Safari keeps its bars in a tab. Share → Add to Home Screen for true full screen.');
        }
    },

    // ── Numbers, for when names are not enough ──────────────────────────
    //
    // Chrome's profile picker shows four buttons all called "Alex". Saying
    // the name cannot pick the third one, and refusing an ambiguous match —
    // right as that is — leaves you stuck with no way through. So: numbers
    // drawn over the picture, and you say the one you want.
    //
    // The badges are drawn HERE, on the phone, over its own screenshot.
    // Nothing is painted on the Mac, so what you are looking at stays exactly
    // what the Mac looks like.

    numbers: [],

    /// Has the full pending list been fetched at least once this
    /// session? Until it has, an empty or one-card map means "not
    /// loaded", not "not waiting".
    approvalsLoaded: false,

    /// Bumped on every unpair, so an answer in flight for the previous
    /// Mac cannot repopulate state that belongs to this one.
    ///
    /// Read `era()` before any await, `sameEra(era)` after it. Adding
    /// this to `loadApprovals` alone was not enough: the screenshot
    /// poll put Mac A's picture back after an unpair (and taps then
    /// went to Mac B at coordinates read off Mac A's screen), the
    /// policy sheet repainted Mac A's exception list with live
    /// handlers, the number badges kept Mac A's targets, and
    /// `startHandsFree` opened the microphone after the unpair that
    /// was supposed to have stopped it. Every one of those is the same
    /// bug; this is the one rule that covers them.
    pairingGeneration: 0,

    era() { return this.pairingGeneration; },
    sameEra(era) { return this.pairingGeneration === era && !!this.baseUrl && !!this.token; },

    /// A "remember this app" waiting on an "Are you sure?".
    pendingRemember: null,

    /// The approval a tapped notification named, until it is shown.
    focusApproval: null,

    async toggleNumbers() {
        const layer = document.getElementById('numbersLayer');
        if (!layer) return;
        if (layer.classList.contains('on')) { this.hideNumbers(); return; }
        await this.showNumbers();
    },

    async showNumbers() {
        const layer = document.getElementById('numbersLayer');
        if (!layer) return;
        if (!this.baseUrl || !this.token) return;
        // Badges name positions on ONE Mac's screen. Left up across an
        // unpair they went on floating over the next Mac's picture, and
        // saying "3" taps that Mac wherever the old one's third control
        // happened to be.
        const era = this.era();
        try {
            const rows = await fetch(`${this.baseUrl}/api/controls`, {
                cache: 'no-store',
                headers: { 'Authorization': `Bearer ${this.token}` },
            }).then(r => r.json());
            if (!this.sameEra(era)) return;
            if (rows && rows.error) {
                // Say what actually went wrong. "Nothing pressable on screen"
                // was a lie told on behalf of a driver whose session had died.
                // And take the old badges down on the way out: numbers from
                // the last screen, floating over this one, are worse than no
                // numbers — you would say "6" and press something else.
                this.hideNumbers();
                this.toast(String(rows.error).slice(0, 120), true);
                return;
            }
            if (!this.sameEra(era)) return;
            this.numbers = Array.isArray(rows) ? rows : [];
        } catch (e) {
            this.hideNumbers();
            this.toast('Could not read the screen', true);
            return;
        }
        layer.textContent = '';
        // Badges that land on top of each other are worse than none: your
        // screenshot had eight stacked in a pile with only the top one
        // readable. Keep the first at any spot and drop the rest — a control
        // you cannot see a number for is one you would not have asked for.
        const placed = [];
        const minGap = 0.028;   // as a fraction of the picture
        const kept = [];
        for (const row of this.numbers) {
            const cx = row.x + row.w / 2;
            const cy = row.y + row.h / 2;
            if (placed.some(p => Math.abs(p.cx - cx) < minGap && Math.abs(p.cy - cy) < minGap)) continue;
            placed.push({ cx, cy });
            kept.push(row);
        }
        // Renumber so what you see runs 1..n with no gaps to trip over.
        this.numbers = kept.map((row, i) => ({ ...row, n: i + 1 }));
        for (const row of this.numbers) {
            const tag = document.createElement('b');
            // textContent: a window title is untrusted text.
            tag.textContent = String(row.n);
            tag.title = row.label || '';
            layer.appendChild(tag);
        }
        this.drawNumbers();
        layer.classList.add('on');
        this.syncNumbersButton(true);
        if (!this.numbers.length) {
            // Distinguish the two reasons for an empty overlay: there really
            // is nothing pressable, or what is in front is on a display this
            // phone is not being shown.
            this.toast('Nothing pressable on the screen you can see', true);
            this.hideNumbers();
            return;
        }
        this.toast(`${this.numbers.length} things you can press — say a number`);
    },

    /// Put each badge where its control actually is, right now.
    ///
    /// Percentages of the frame do not work. Zoom is a transform on the
    /// IMAGE, so the picture slides and scales underneath a layer that is
    /// pinned to the frame — the badges stayed exactly where they were while
    /// the content moved out from under them, which is worse than useless
    /// because the numbers then point at the wrong things.
    ///
    /// So they are placed from `imageRect()` in viewport coordinates, the
    /// same way the pointer is, because that rect already accounts for the
    /// zoom, the letterboxing and the safe-area padding.
    drawNumbers() {
        const layer = document.getElementById('numbersLayer');
        const stage = document.getElementById('screenStage');
        if (!layer || !stage || !layer.classList.contains('on')) return;
        const rect = this.imageRect();
        if (!rect) return;
        const frame = stage.getBoundingClientRect();

        const tags = layer.children;
        for (let i = 0; i < tags.length && i < this.numbers.length; i++) {
            const row = this.numbers[i];
            const tag = tags[i];
            const x = rect.left + (row.x + row.w / 2) * rect.width;
            const y = rect.top + (row.y + row.h / 2) * rect.height;
            // A badge for something scrolled out of the magnified view points
            // at nothing you can see, so it is not shown at all.
            const visible = x >= frame.left && x <= frame.right
                         && y >= frame.top && y <= frame.bottom;
            tag.style.display = visible ? '' : 'none';
            tag.style.left = `${x}px`;
            tag.style.top = `${y}px`;
        }
    },

    hideNumbers() {
        const layer = document.getElementById('numbersLayer');
        if (!layer) return;
        layer.classList.remove('on');
        layer.textContent = '';
        this.numbers = [];
        this.syncNumbersButton(false);
    },

    syncNumbersButton(on) {
        const btn = document.getElementById('numbersBtn');
        if (btn) btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    },

    /// "3", "number 3", "press 3" — press the badge with that number.
    pressNumber(spoken) {
        if (!this.numbers.length) return false;
        const said = String(spoken || '').toLowerCase()
            .replace(/[.!?]+$/, '')
            .replace(/^(click|press|tap|pick|choose|select|number|option)\s+/g, '')
            .replace(/^number\s+/, '')
            .trim();
        const words = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6,
                        seven: 7, eight: 8, nine: 9, ten: 10 };
        const n = /^\d+$/.test(said) ? parseInt(said, 10) : words[said];
        if (!n) return false;
        const row = this.numbers.find(r => r.n === n);
        if (!row) { this.toast(`There is no ${n}`, true); return true; }
        // Press its centre, the same path a tap on the picture uses.
        //
        // And wait for the answer before claiming it happened. This said
        // "Pressed 3 — Continue" whether the Mac had pressed anything, was
        // unreachable, or had answered {"ok":false} — the promise was
        // swallowed and never read.
        this.hideNumbers();
        this.tapAt(row.x + row.w / 2, row.y + row.h / 2).then(result => {
            if (result && result.ok === false) {
                this.toast(result.reason || `Could not press ${n}`, true);
            } else if (!result) {
                this.toast('Could not reach your Mac — try again', true);
            } else {
                this.toast(`Pressed ${n} — ${row.label || 'control'}`);
            }
        });
        return true;
    },

    /// Resolves to the Mac's answer, or to null when it could not be reached.
    tapAt(x, y) {
        if (!this.baseUrl || !this.token) return Promise.resolve(null);
        return fetch(`${this.baseUrl}/api/tap`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ x, y, kind: 'click' }),
        }).then(r => r.json()).catch(() => null);
    },

    // Fit the whole Mac, or fill the phone.
    //
    // A 16:10 desktop on a 19.5:9 phone cannot do both: fitting leaves bars
    // down the sides, filling crops the top and bottom off. Fitting is the
    // default because you cannot press what you cannot see — but the bars
    // waste a lot of a small screen, so this is a choice rather than a rule.
    applyScreenFill() {
        const fill = localStorage.getItem('allowly-screen-fill') === '1';
        document.body.classList.toggle('screen-fill', fill);
        const btn = document.getElementById('fillToggle');
        if (btn) {
            btn.textContent = fill ? 'Fit' : 'Fill';
            btn.setAttribute('aria-label', fill ? 'Show the whole Mac screen' : 'Fill the phone screen');
        }
        this.drawAim();
    },

    toggleScreenFill() {
        const fill = localStorage.getItem('allowly-screen-fill') === '1';
        localStorage.setItem('allowly-screen-fill', fill ? '0' : '1');
        this.applyScreenFill();
        this.toast(fill ? 'Showing the whole screen' : 'Filling the screen — edges are cropped');
    },

    // Pull frames only while the Screen tab is visible. Capturing and shipping
    // a full-resolution JPEG is not free, so it must stop when nobody is
    // looking — including when the phone is backgrounded.
    pollScreenOnce() {
        if (document.hidden) return;
        // `screenTick` is only assigned once `startScreenPolling` has
        // run. Called before that — the page becoming visible on a
        // phone that has not paired yet — this threw on a null.
        if (this.screenTick) this.screenTick();
    },

    startScreenPolling() {
        if (this.screenTimer) return;
        this.installScreenGestures();
        this.installCursorDrag();
        const tick = (force = false) => {
            // "Hidden" must never mean "show nothing, forever, silently".
            //
            // Skipping the fetch while the phone is backgrounded is right —
            // there is no point streaming JPEGs to a screen nobody is
            // looking at. But if we have never painted a single frame, the
            // user is staring at a black rectangle with no explanation, and
            // on iOS this flag is not always the truth: a foregrounded PWA
            // has been observed reporting hidden. One frame costs little and
            // removes the failure entirely.
            if (document.hidden && !force) return;
            const img = document.getElementById('screenImage');
            const status = document.getElementById('screenStatus');
            const started = Date.now();
            if (!this.baseUrl || !this.token) {
                status.textContent = 'Not paired — open the pairing link again';
                return;
            }
            // Only say something while it is NOT working. A healthy stream
            // refreshes every second, so "Fetching…" and "updated 812 ms ago"
            // were a caption that flickered developer-speak at you forever and
            // told you nothing you could act on. Silence means it is fine.
            if (!img.src) status.textContent = 'Waking the Mac…';
            this.lastFrameTry = started;
            const era = this.era();
            // Belt and braces: a changing query defeats any cache that ignores
            // no-store, which is what left the view stuck on an old workspace.
            fetch(`${this.baseUrl}/api/screenshot?token=${encodeURIComponent(this.token)}&t=${started}`,
                  { cache: 'no-store' })
                .then(r => r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`)))
                .then(({ data, cursor }) => {
                    // The most dangerous one to get wrong. A frame in
                    // flight at an unpair used to land afterwards and put
                    // the old Mac's picture back — so after pairing with a
                    // second Mac you would be looking at the first Mac's
                    // screen while every tap went to the second, at the
                    // coordinates you read off the wrong picture.
                    if (!this.sameEra(era)) return;
                    if (!data) throw new Error('empty frame');
                    img.src = `data:image/jpeg;base64,${data}`;
                    // The Mac's own cursor is in the frame already. We do
                    // not mirror it — ours is a separate thing you aim with,
                    // redrawn because the picture may have resized.
                    this.drawAim();
                    status.textContent = '';
                })
                .catch(() => {
                    if (!this.sameEra(era)) return;
                    status.textContent = 'Cannot see the Mac right now — retrying';
                });
        };
        this.screenTick = tick;
        tick();

        // A watchdog, because a stalled stream is indistinguishable from a
        // broken app: you get a black strip and no explanation.
        //
        // The tick returns early whenever the page is hidden, which is right
        // — but if it is hidden at the moment polling starts, or the timer is
        // lost to a suspend, nothing ever paints and nothing ever says why.
        // This notices a frame that never arrived and asks again.
        clearInterval(this.screenWatchdog);
        this.screenWatchdog = setInterval(() => {
            const el = document.getElementById('screenImage');
            if (!el) return;
            // No picture at all is the one state worth overriding "hidden"
            // for, because it is indistinguishable from a broken app.
            if (!el.src) {
                const note = document.getElementById('screenStatus');
                if (note) note.textContent = 'Waking the Mac…';
                tick(true);
                return;
            }
            if (document.hidden) return;
            if (!this.lastFrameTry || (Date.now() - this.lastFrameTry) > 4000) tick();
        }, 3000);
        // Tighter cadence while you are driving the pointer, or while the
        // stream fills the screen; it matters far more when you are aiming at
        // something, or actually watching, than when it is a thumbnail.
        // Full screen means you are watching rather than glancing.
        const busy = document.body.classList.contains('fullscreen');
        this.screenTimer = setInterval(tick, busy ? 400 : 1000);
    },

    stopScreenPolling() {
        // The watchdog and the nudge as well. Clearing only the poll
        // left two timers running for the life of the page after an
        // unpair — harmless, because everything they touch is guarded,
        // but "stop polling" should mean it.
        if (this.screenTimer) {
            clearInterval(this.screenTimer);
            this.screenTimer = null;
        }
        if (this.screenWatchdog) {
            clearInterval(this.screenWatchdog);
            this.screenWatchdog = null;
        }
        if (this.screenNudge) {
            clearTimeout(this.screenNudge);
            this.screenNudge = null;
        }
    },

    // The Mac asked for text — "type here", "enter password here". The field
    // it wants is already focused there, so this only has to collect the
    // characters. A password typed here is never spoken, transcribed or logged.
    promptForInput(field, secret) {
        const textEl = document.getElementById('typeText');
        const fieldEl = document.getElementById('typeField');
        const secretEl = document.getElementById('typeSecret');
        const status = document.getElementById('typeStatus');
        const heading = document.querySelector('#inputSheet h2');

        textEl.value = '';
        // The Mac already clicked the field, so naming it again would move the
        // focus somewhere else.
        fieldEl.value = '';
        secretEl.checked = !!secret;
        textEl.type = secret ? 'password' : 'text';
        if (heading) heading.textContent = secret ? 'Enter the password' : 'Type on the Mac';
        status.textContent = secret
            ? 'Goes straight to the focused field. Never spoken, never logged.'
            : 'Goes wherever the pointer is on the Mac.';

        this.openSheet('inputSheet');
        // iOS needs the focus call in the same turn the sheet becomes visible.
        setTimeout(() => textEl.focus(), 120);
    },

    // The Mac read a form off its own screen. Show it as a real form here so
    // you can see which box each value is going into — typing blind into a
    // remote screen is how the wrong thing ends up in the password field.
    // Older daemons send { type: "form", fields: [...] }. Same thing, less
    // structure — lift it into a Spec rather than keeping a second renderer.
    specFromFields(fields) {
        const elements = {};
        const state = {};
        const children = [];
        fields.forEach((field, index) => {
            const id = `f${index}`;
            state[id] = '';
            children.push(id);
            elements[id] = {
                component: 'Input',
                props: { label: field.label, target: field.realLabel || field.label,
                         secret: !!field.secret, kind: field.kind, $bindState: id },
            };
        });
        children.push('submit');
        elements.submit = { component: 'Button', props: { label: 'Fill on the Mac', action: 'submit' } };
        elements.root = { component: 'Panel', props: { title: 'Fill this in' }, slots: { children } };
        return { root: 'root', state, elements };
    },

    // ── Rendering a Spec ────────────────────────────────────────────────
    //
    // The Mac sends a json-render Spec: flat `elements` keyed by id, one
    // `root`, and a `state` map the inputs bind into. We took the format and
    // left the library — json-render is React and this app is four static
    // files the daemon serves straight off disk.
    //
    // The point of a Spec rather than a screenshot: a real keyboard, real
    // autofill, a password manager that works, and a field you can name out
    // loud. Poking at a JPEG of someone else's form gives you none of that.
    //
    // Deliberately a dumb interpreter. Six components, two binding forms, one
    // action. Anything it does not recognise is skipped rather than guessed
    // at, so a Spec from a newer Mac cannot render as nonsense.
    SPEC_COMPONENTS: ['Panel', 'Heading', 'Input', 'Select', 'Switch', 'Button'],

    showSpec(spec) {
        const list = document.getElementById('formFields');
        const status = document.getElementById('formStatus');
        if (!list || !spec || !spec.elements) return;

        list.innerHTML = '';
        status.textContent = '';
        // A new form arms nothing. Carrying `focusedField` across
        // meant a second form sharing a state key — "email" is the
        // obvious one — arrived with that box armed and no highlight,
        // so "type andres" filled a field nobody had selected.
        this.focusedField = null;
        this.spec = spec;
        this.specState = Object.assign({}, spec.state || {});
        this.specFields = {};          // state key -> { input, label, kind }

        const rootId = spec.root || 'root';
        // Each id is rendered at most once. The depth limit alone stopped a
        // cycle from hanging, but root -> a -> root still drew the whole form
        // four times before it ran out of depth.
        this.specSeen = new Set();
        const rendered = this.renderSpecNode(rootId, 0);
        if (rendered) list.appendChild(rendered);

        // The sheet's own heading carries the title, so the Panel does not
        // repeat it.
        const heading = document.querySelector('#formSheet h2');
        const rootEl = spec.elements[rootId];
        if (heading && rootEl && rootEl.props && rootEl.props.title) {
            heading.textContent = rootEl.props.title;
        }

        this.openSheet('formSheet');
        setTimeout(() => list.querySelector('input, select')?.focus(), 120);
    },

    renderSpecNode(id, depth) {
        // A Spec is a tree by convention, not by construction; a cycle in the
        // ids would otherwise hang the phone.
        if (depth > 8) return null;
        if (this.specSeen.has(id)) return null;
        this.specSeen.add(id);
        const node = this.spec.elements[id];
        if (!node || this.SPEC_COMPONENTS.indexOf(node.component) === -1) return null;
        const props = node.props || {};

        switch (node.component) {
            case 'Panel': {
                const panel = document.createElement('div');
                panel.className = 'spec-panel';
                const kids = (node.slots && node.slots.children) || [];
                kids.forEach(childId => {
                    const child = this.renderSpecNode(childId, depth + 1);
                    if (child) panel.appendChild(child);
                });
                return panel;
            }
            case 'Heading': {
                const h = document.createElement('h3');
                h.className = 'spec-heading';
                h.textContent = props.label || '';
                return h;
            }
            case 'Input':
                return this.renderSpecInput(id, props);
            case 'Select':
                return this.renderSpecSelect(id, props);
            case 'Switch':
                return this.renderSpecSwitch(id, props);
            case 'Button': {
                const b = document.createElement('button');
                b.type = 'button';
                b.className = 'btn btn-primary';
                b.textContent = props.label || 'Done';
                // Actions are named by the Mac, never invented here.
                b.addEventListener('click', () => {
                    if (props.action === 'submit') this.submitForm();
                });
                return b;
            }
            default:
                return null;
        }
    },

    // Tapping a field arms it for voice: "type andres" then fills THIS one.
    armField(key) {
        this.focusedField = key;
        document.querySelectorAll('.spec-field').forEach(el => {
            el.classList.toggle('armed', el.dataset.key === key);
        });
    },

    renderSpecField(key, props, control) {
        const wrap = document.createElement('label');
        wrap.className = 'spec-field';
        wrap.dataset.key = key;

        const caption = document.createElement('span');
        caption.textContent = props.label || key;
        wrap.appendChild(caption);
        wrap.appendChild(control);

        const arm = () => this.armField(key);
        control.addEventListener('focus', arm);
        wrap.addEventListener('click', arm);
        return wrap;
    },

    renderSpecInput(id, props) {
        const key = props.$bindState || id;
        const input = document.createElement('input');
        input.className = 'setting-input';
        input.autocapitalize = 'off';
        input.spellcheck = false;
        input.type = props.secret ? 'password' : 'text';
        input.autocomplete = props.secret ? 'current-password' : 'off';
        // Best-effort keyboard hints from the label and the AX role.
        const label = String(props.label || '');
        if (!props.secret && /e-?mail/i.test(label)) input.type = 'email';
        if (!props.secret && /phone|mobile|tel/i.test(label)) input.type = 'tel';
        if (!props.secret && /number|amount|qty|quantity/i.test(label)) input.inputMode = 'numeric';
        input.value = this.specState[key] || '';
        input.addEventListener('input', () => { this.specState[key] = input.value; });

        this.specFields[key] = { input, label: props.label || key,
                                 target: props.target || props.label || key,
                                 secret: !!props.secret };
        return this.renderSpecField(key, props, input);
    },

    renderSpecSelect(id, props) {
        const key = props.$bindState || id;
        const select = document.createElement('select');
        select.className = 'setting-input';
        (props.options || []).forEach(option => {
            const value = typeof option === 'string' ? option : option.value;
            const text = typeof option === 'string' ? option : (option.label || option.value);
            const el = document.createElement('option');
            el.value = value;
            el.textContent = text;
            el.selected = value === this.specState[key];
            select.appendChild(el);
        });
        select.addEventListener('change', () => { this.specState[key] = select.value; });

        this.specFields[key] = { input: select, label: props.label || key,
                                 target: props.target || props.label || key,
                                 choices: props.options || [] };
        return this.renderSpecField(key, props, select);
    },

    renderSpecSwitch(id, props) {
        const key = props.$bindState || id;
        const row = document.createElement('label');
        row.className = 'setting-row spec-field';
        row.dataset.key = key;

        const caption = document.createElement('span');
        caption.textContent = props.label || key;

        const input = document.createElement('input');
        input.type = 'checkbox';
        input.checked = this.specState[key] === true || this.specState[key] === 'true';
        input.addEventListener('change', () => { this.specState[key] = input.checked; });

        row.appendChild(caption);
        row.appendChild(input);
        row.addEventListener('click', () => this.armField(key));

        this.specFields[key] = { input, label: props.label || key,
                                 target: props.target || props.label || key, toggle: true };
        return row;
    },

    async submitForm() {
        // An await loop over the fields. `changePairing` nulls
        // `specFields` underneath it, which threw outside the try and
        // painted an unhandled rejection across the status line.
        if (!this.baseUrl || !this.token) return;
        const era = this.era();
        const status = document.getElementById('formStatus');
        const keys = Object.keys(this.specFields || {})
            .filter(key => String((this.specState || {})[key] ?? '') !== '');
        if (!keys.length) { status.textContent = 'Nothing to fill'; return; }

        status.textContent = 'Filling…';
        // Snapshot the fields. The loop awaits between each one, and
        // `changePairing` nulls `specFields` underneath it — which threw
        // OUTSIDE the try and painted an unhandled rejection across the
        // screen status line. The entry guard could never have fixed
        // that, because the nulling happens after the guard passes.
        const fields = this.specFields;
        const values = keys.map(key => String(this.specState[key]));
        let done = 0;
        for (const [index, key] of keys.entries()) {
            // And stop outright if the Mac changed mid-fill, rather than
            // sending the remaining fields — one of which may be a
            // password — to a machine that never asked for them.
            if (!this.sameEra(era)) return;
            // …and stop if the FORM was replaced. A `spec` push lands
            // between the awaits and swaps `specFields` wholesale
            // without the pairing changing, so the loop went on typing
            // the old form's values into the new one — and for a
            // labelled field the address is the form's own name, so a
            // second site with a box called "Password" would receive
            // the first site's password and report success.
            if (this.specFields !== fields) {
                // Say it. Some fields WERE typed, and the user is now
                // looking at a fresh empty form with no idea of that.
                this.toast(`That form changed — ${done} field${done === 1 ? '' : 's'} went in before it did`, true);
                return;
            }
            const field = fields[key];
            if (!field) break;
            try {
                // Sequentially: each fill focuses a different field on the
                // Mac, and firing them together races the focus.
                const response = await fetch(`${this.baseUrl}/api/type`, {
                    method: 'POST',
                    cache: 'no-store',
                    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
                    body: JSON.stringify({
                        text: values[index],
                        // The Mac's own name for it, not the one shown here:
                        // Jev may have named an unlabelled field for you.
                        field: field.target || field.label,
                        secret: !!field.secret,
                    }),
                });
                const result = await response.json();
                if (result.ok) done += 1;
                else status.textContent = result.reason || `Could not fill ${field.label}`;
            } catch (error) {
                status.textContent = `Failed on ${field.label}: ${error.message}`;
                // Clear the secret before leaving. Breaking here skipped
                // the cleanup three lines down, so a network failure was
                // the one path that left the password sitting in the box
                // and in `specState` — the opposite of what the comment
                // below promises, and of what `sendTypedText` does.
                if (field.secret) {
                    values[index] = '';
                    if (this.specState) this.specState[key] = '';
                    if (field.input) field.input.value = '';
                }
                break;
            }
            // Never leave a password sitting in the phone's memory or DOM.
            if (field.secret) {
                values[index] = '';
                if (this.specState) this.specState[key] = '';
                if (field.input) field.input.value = '';
            }
        }
        if (done === keys.length) {
            status.textContent = `Filled ${done} field${done === 1 ? '' : 's'}`;
            setTimeout(() => { this.focusedField = null; this.closeSheet('formSheet'); }, 900);
        }
    },

    // Send typed text to the Mac. Passwords belong here rather than in the
    // microphone: nothing is transcribed, and secret text is never logged.
    sendTypedText() {
        if (!this.baseUrl || !this.token) return;
        const era = this.era();
        const textEl = document.getElementById('typeText');
        const fieldEl = document.getElementById('typeField');
        const secretEl = document.getElementById('typeSecret');
        const status = document.getElementById('typeStatus');
        const text = textEl.value;
        if (!text) { status.textContent = 'Nothing to send'; return; }

        const payload = { text, secret: secretEl.checked };
        const field = fieldEl.value.trim();
        if (field) payload.field = field;

        status.textContent = 'Sending…';
        fetch(`${this.baseUrl}/api/type`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify(payload),
        })
            .then(r => r.json())
            .then(result => {
                // Clear the secret FIRST, and whatever the era says. A
                // password must not survive in the box because the Mac
                // changed underneath the request.
                //
                // Closing, not just clearing. An open sheet with the
                // secret box still ticked keeps `secretFieldArmed` true,
                // so every push-to-talk and every hands-free utterance
                // afterwards was refused with "Type a password — never
                // say it out loud" until the sheet was dismissed by
                // hand. The password is sent; the sheet has no further
                // business being open.
                const wasSecret = secretEl.checked;
                if (wasSecret) { textEl.value = ''; this.closeSheet('inputSheet'); }
                if (!this.sameEra(era)) return;
                const said = result.reason || (result.ok ? 'Sent' : 'Failed');
                // The sheet that would have shown this is now closed, so
                // the outcome has to go somewhere the person can see it.
                if (wasSecret) { this.toast(said, !result.ok); return; }
                status.textContent = said;
            })
            .catch(err => {
                // The box is cleared but the sheet stays: the send
                // failed, and dropping the person back to the main
                // screen with no explanation is how you retype a
                // password into the wrong place.
                if (secretEl.checked) textEl.value = '';
                if (this.sameEra(era)) status.textContent = `Failed: ${err.message}`;
            });
    },

    // Hands free: watch the microphone level, record an utterance when speech
    // starts, stop on silence, upload. Each utterance is a complete recording,
    // which avoids the streaming problem entirely — MediaRecorder chunks after
    // the first cannot be decoded on their own.
    // Hands-free state rides on the connection pill in the header, not on a
    // line of its own down the page. It is the same kind of fact as
    // "Connected" — whether the app is live right now — and one badge that
    // changes is easier to read at a glance than two places to look.
    // `cls` is '' | 'live' (listening) | 'hearing'.
    setHandsFreeStatus(text, cls) {
        this.voiceState = cls || '';
        // The long form still goes in Settings, where there is room for it
        // and where a microphone failure needs to be readable.
        const sheet = document.getElementById('handsFreeStatus');
        if (sheet) { sheet.textContent = text; sheet.className = 'policy-hint'; }
        this.updateStatusPill();
    },

    // One writer for the pill, so connection and voice cannot fight over it.
    updateStatusPill() {
        const pill = document.getElementById('connectionStatus');
        const text = document.getElementById('statusText');
        if (!pill || !text) return;

        const connected = !!this.state.connected;
        const voice = this.handsFree ? this.voiceState : '';

        let label, mode;
        if (!connected) { label = 'Disconnected'; mode = 'disconnected'; }
        else if (voice === 'hearing') { label = 'Hearing you'; mode = 'hearing'; }
        else if (voice === 'live') { label = 'Listening'; mode = 'listening'; }
        else { label = 'Connected'; mode = 'connected'; }

        pill.classList.remove('connected', 'disconnected', 'listening', 'hearing');
        pill.classList.add(mode);
        text.textContent = label;
    },

    syncHandsFreeToggles(on) {
        const toggle = document.getElementById('handsFree');
        if (toggle) toggle.checked = on;
        document.getElementById('pttBtn')?.classList.toggle('hidden', on);
        // Hides the now-redundant Voice heading and button; the pill says it.
        document.body.classList.toggle('handsfree', !!on);
        if (!on) this.voiceState = '';
        this.updateStatusPill();
    },

    async startHandsFree() {
        // No Mac, no microphone. Unpairing leaves a one-shot arm
        // listener on the document, and the tap that unpairs bubbles
        // straight into it — so this could be reached with nothing to
        // send a recording to.
        //
        // Checked again AFTER getUserMedia, because the guard on its
        // own was not enough: with permission already granted the
        // promise resolves in tens of milliseconds, and an unpair
        // inside that window could not stop it — `stopHandsFree` bails
        // when `handsFree` is still null, so the continuation went on
        // to open the session, write the preference back, and start
        // recording for a Mac that is no longer paired.
        if (!this.baseUrl || !this.token) return;
        if (this.handsFree) return;
        const era = this.era();
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            // Unpaired while the permission promise was in flight. Give
            // the microphone straight back rather than opening a session
            // for a Mac that is gone.
            if (!this.sameEra(era)) {
                stream.getTracks().forEach(t => t.stop());
                return;
            }
            const context = new (window.AudioContext || window.webkitAudioContext)();
            const source = context.createMediaStreamSource(stream);
            const analyser = context.createAnalyser();
            analyser.fftSize = 1024;
            source.connect(analyser);

            const samples = new Uint8Array(analyser.frequencyBinCount);
            let speaking = false;
            let quietSince = 0;
            let segmentStarted = 0;
            let chunks = [];
            let recorder = null;

            this.handsFree = { stream, context, stop: false };
            localStorage.setItem('allowly-hands-free', 'true');
            this.syncHandsFreeToggles(true);
            this.setHandsFreeStatus('Listening…', 'live');

            // Record CONTINUOUSLY and cut on silence, rather than starting the
            // recorder when speech is detected. Starting on detection always
            // clips the first word — "quit Notes" arrived as "Notes", which
            // then reads as a bare app name and opens it.
            const startRecorder = () => {
                chunks = [];
                segmentStarted = Date.now();
                // The same container negotiation push-to-talk does.
                // Without it Chromium defaults to WebM/Opus, which
                // Apple Speech cannot open at all — so every hands-free
                // utterance failed transcription while the button
                // worked, which reads as "hands-free is broken".
                recorder = new MediaRecorder(stream, this.recorderOptions());
                recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
                recorder.onstop = () => {
                    // The session check FIRST. `stopHandsFree` stops the
                    // tracks, which drives the recorder inactive and
                    // fires this — and uploading before checking meant
                    // the segment that was mid-capture at the unpair was
                    // still sent, to a Mac that is no longer paired.
                    if (!this.handsFree) return;
                    const blob = new Blob(chunks, { type: recorder.mimeType || 'audio/mp4' });
                    const spoke = recorder.jevHadSpeech;
                    if (spoke && blob.size > 6000) this.uploadAudio(blob);
                    if (!this.handsFree.stop) startRecorder();
                };
                recorder.jevHadSpeech = false;
                recorder.start();
            };
            startRecorder();

            const tick = () => {
                if (!this.handsFree || this.handsFree.stop) return;
                analyser.getByteTimeDomainData(samples);
                let sum = 0;
                for (const v of samples) { const d = v - 128; sum += d * d; }
                const level = Math.sqrt(sum / samples.length);
                const now = Date.now();
                // Show the level. This is the difference between "it is not
                // hearing me" and "it heard me and is still thinking", which
                // was impossible to tell apart from a silent screen.
                this.showVoiceLevel(level, speaking);

                if (level > 6) {
                    quietSince = 0;
                    if (!speaking) {
                        speaking = true;
                        if (recorder) recorder.jevHadSpeech = true;
                        this.setHandsFreeStatus('Hearing you…', 'hearing');
                    }
                } else if (speaking) {
                    if (!quietSince) quietSince = now;
                    if (now - quietSince > 750) {
                        speaking = false;
                        quietSince = 0;
                        this.setHandsFreeStatus('Listening…', 'live');
                        // Stopping produces a complete file containing the lead-in
                        // as well as the speech, then onstop starts the next one.
                        try { recorder.stop(); } catch (e) { /* already stopping */ }
                    }
                } else if (now - segmentStarted > 12000) {
                    // Nothing said for a while: roll the recorder over so the
                    // buffer of silence cannot grow without bound.
                    try { recorder.stop(); } catch (e) { /* already stopping */ }
                }
                requestAnimationFrame(tick);
            };
            tick();
        } catch (err) {
            this.setHandsFreeStatus(`Microphone unavailable: ${err.message}`, '');
            this.syncHandsFreeToggles(false);
            localStorage.removeItem('allowly-hands-free');
        }
    },

    stopHandsFree() {
        if (!this.handsFree) return;
        this.hideVoiceLevel();
        this.handsFree.stop = true;
        this.handsFree.stream.getTracks().forEach(t => t.stop());
        this.handsFree.context.close().catch(() => {});
        this.handsFree = null;
        localStorage.removeItem('allowly-hands-free');
        this.syncHandsFreeToggles(false);
        this.setHandsFreeStatus('Off', '');
    },

    // Turn touches on the screen image into pointer events on the Mac.
    //
    // Tap = click, double tap = double click, long press = right click,
    // drag after a long press = drag, one-finger move = scroll. That is the
    // set a trackpad gives you, which is what makes a remote screen usable
    // rather than merely clickable.
    pointAt(event) {
        const img = document.getElementById('screenImage');
        const rect = img.getBoundingClientRect();
        const touch = event.changedTouches ? event.changedTouches[0] : event;
        return {
            x: (touch.clientX - rect.left) / rect.width,
            y: (touch.clientY - rect.top) / rect.height,
            clientX: touch.clientX,
            clientY: touch.clientY,
        };
    },

    sendPointer(kind, point) {
        if (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) return Promise.resolve();
        if (!this.baseUrl || !this.token) return Promise.resolve();
        const era = this.era();
        return fetch(`${this.baseUrl}/api/tap`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ x: point.x, y: point.y, kind }),
        })
            .then(r => r.json())
            .then(result => {
                // Otherwise this re-arms the nudge timer that unpairing
                // just cleared, and writes the old Mac's reason into the
                // status line.
                if (!this.sameEra(era)) return;
                const status = document.getElementById('screenStatus');
                if (status && result.reason) status.textContent = result.reason;
                // Pull a frame straight away so you see the effect immediately
                // rather than waiting for the next poll.
                this.refreshScreenSoon();
            })
            .catch(() => {});
    },

    sendSwipe(point, dx, dy) {
        if (!this.baseUrl || !this.token) return;
        const era = this.era();
        fetch(`${this.baseUrl}/api/swipe`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ x: point.x, y: point.y, dx, dy }),
        }).then(() => { if (this.sameEra(era)) this.refreshScreenSoon(); }).catch(() => {});
    },

    refreshScreenSoon() {
        // The nudge re-armed a timer that unpairing had just cleared.
        // Deciding it here covers every caller at once, rather than
        // each `.then` remembering.
        if (!this.baseUrl || !this.token) return;
        clearTimeout(this.screenNudge);
        this.screenNudge = setTimeout(() => this.pollScreenOnce(), 120);
    },

    showTapMarker(clientX, clientY) {
        const marker = document.createElement('div');
        marker.className = 'tap-marker';
        marker.style.left = `${clientX}px`;
        marker.style.top = `${clientY}px`;
        document.body.appendChild(marker);
        setTimeout(() => marker.remove(), 400);
    },

    // Show the Mac's pointer, and let it be moved without clicking.
    //
    // Seeing where the pointer is turns "this" and "here" into something you
    // can say: aim once with a finger, then speak. For small targets that
    // beats numbering the whole screen and reading a number back.
    // The aim point.
    //
    // Stored in IMAGE coordinates (0..1 across the picture), not viewport
    // pixels. That is the whole trick: zoom in, zoom out, scroll the page —
    // it stays on the same pixel of your Mac, because the Mac pixel is what
    // it means. Storing viewport pixels is why it used to slide off the
    // picture and vanish the moment you zoomed back out.
    //
    // It may sit a little outside 0..1 so it can be parked off the picture,
    // but never far enough to be unreachable.
    aim: { x: 0.5, y: 0.5 },
    OFF: 0.12,              // how far outside the picture it may be parked

    // Where the picture currently is on screen. Reflects the zoom transform,
    // because getBoundingClientRect does.
    imageRect() {
        const img = document.getElementById('screenImage');
        if (!img || !img.naturalWidth) return null;
        const box = img.getBoundingClientRect();
        if (box.width < 1 || box.height < 1) return null;

        // Where the PICTURE is, not where its element is.
        //
        // Normally those are the same box. In full screen they are not: the
        // element is stretched over the whole stage and the picture is
        // letterboxed inside it by object-fit, with safe-area padding around
        // that. Measuring the element put the pointer somewhere the picture
        // was not — visible, but nowhere near the pixel it claimed, and
        // impossible to aim with.
        const style = window.getComputedStyle(img);
        const scale = this.screenScale || 1;
        const pad = (side) => (parseFloat(style.getPropertyValue(side)) || 0) * scale;
        const left = box.left + pad('padding-left');
        const top = box.top + pad('padding-top');
        const width = box.width - pad('padding-left') - pad('padding-right');
        const height = box.height - pad('padding-top') - pad('padding-bottom');
        if (width < 1 || height < 1) return null;

        if (style.objectFit !== 'contain' && style.objectFit !== 'cover') {
            return new DOMRect(left, top, width, height);
        }
        // contain: the picture keeps its aspect ratio and is centred, so the
        // spare space becomes bars that are part of the element but not of
        // the image. Those bars must not be aimable.
        //
        // cover: the opposite — the picture is larger than the box and the
        // overflow is cropped. The rect it returns therefore extends past the
        // frame on purpose, so aiming still maps to the right Mac pixel; the
        // marker is clamped back into view by drawAim, exactly as it is when
        // zoomed in.
        const fit = style.objectFit === 'cover'
            ? Math.max(width / img.naturalWidth, height / img.naturalHeight)
            : Math.min(width / img.naturalWidth, height / img.naturalHeight);
        const drawnW = img.naturalWidth * fit;
        const drawnH = img.naturalHeight * fit;
        return new DOMRect(
            left + (width - drawnW) / 2,
            top + (height - drawnH) / 2,
            drawnW, drawnH);
    },

    setAim(x, y) {
        const lo = -this.OFF, hi = 1 + this.OFF;
        this.aim = {
            x: Math.min(hi, Math.max(lo, x)),
            y: Math.min(hi, Math.max(lo, y)),
        };
        this.drawAim();
    },

    // Put the marker where the aim point currently lands on screen.
    drawAim() {
        const marker = document.getElementById('cursorMarker');
        const stage = document.getElementById('screenStage');
        const rect = this.imageRect();
        if (!marker) return;
        if (!rect || !stage) { marker.classList.add('hidden'); return; }

        // Where the aimed pixel truly is on screen.
        const x = rect.left + this.aim.x * rect.width;
        const y = rect.top + this.aim.y * rect.height;

        // Magnified, that can be thousands of pixels outside the frame. Pin
        // the MARKER to the frame edge so it stays visible and grabbable — but
        // do not touch this.aim. An earlier version clamped the aim instead,
        // which meant zooming quietly moved which Mac pixel you were pointing
        // at and zooming back out never gave it back. Losing the point that
        // way is the whole complaint this rework exists to fix.
        //
        // Only while magnified. At rest the aim is already bounded to a little
        // past the edges, and parking the pointer just off the picture is
        // allowed on purpose — it may sit inside or outside the screen.
        // Half the marker, so the whole ring stays inside whatever bound it
        // is held to rather than hanging over the edge by its own radius.
        const pad = (marker.offsetWidth || 56) / 2;
        let cx = x, cy = y;
        if (this.screenScale > 1) {
            const frame = stage.getBoundingClientRect();
            cx = Math.min(frame.right - pad, Math.max(frame.left + pad, cx));
            cy = Math.min(frame.bottom - pad, Math.max(frame.top + pad, cy));
        }
        // And never off the phone itself. Parked hard against a corner the
        // true point sits past the edge of the picture on purpose, but the
        // side margins are narrower than that allowance, so without this the
        // marker walks off the right edge of the screen and there is nothing
        // left to grab. Which was the original bug report, word for word.
        cx = Math.min(window.innerWidth - pad, Math.max(pad, cx));
        cy = Math.min(window.innerHeight - pad, Math.max(pad, cy));

        marker.style.left = `${cx}px`;
        marker.style.top = `${cy}px`;
        marker.classList.remove('hidden');
        // Hollow when it is not sitting on the pixel it points at: either off
        // the Mac entirely, or on it but scrolled out of the magnified view.
        const off = this.aim.x < 0 || this.aim.x > 1 || this.aim.y < 0 || this.aim.y > 1;
        this.aimPinned = (cx !== x || cy !== y);
        marker.classList.toggle('off-screen', off || this.aimPinned);
    },

    aimPinned: false,

    // On the picture? Then it can be pressed.
    aimOnScreen() {
        const { x, y } = this.aim;
        if (x < 0 || x > 1 || y < 0 || y > 1) return null;
        return { x, y };
    },

    installCursorDrag() {
        const marker = document.getElementById('cursorMarker');
        if (!marker || marker.dataset.wired) return;
        marker.dataset.wired = '1';

        let active = false;
        let grabDX = 0, grabDY = 0;

        const begin = (event) => {
            if (event.touches && event.touches.length > 1) return;
            event.preventDefault();
            event.stopPropagation();
            const rect = this.imageRect();
            if (!rect) return;
            active = true;
            marker.classList.add('aiming');
            const t = event.changedTouches ? event.changedTouches[0] : event;
            // Grab it where you took hold, so it does not jump under a thumb.
            // Unless it is pinned to the frame edge, in which case the marker
            // is not standing on the pixel it points at and keeping that
            // offset would drag it a screen-width away from your finger.
            // Then it simply comes to where you grabbed it.
            if (this.aimPinned) {
                grabDX = 0; grabDY = 0;
            } else {
                grabDX = (t.clientX - rect.left) / rect.width - this.aim.x;
                grabDY = (t.clientY - rect.top) / rect.height - this.aim.y;
            }
        };

        const move = (event) => {
            if (!active) return;
            event.preventDefault();
            event.stopPropagation();
            const rect = this.imageRect();
            if (!rect) return;
            const t = event.changedTouches ? event.changedTouches[0] : event;
            this.setAim(
                (t.clientX - rect.left) / rect.width - grabDX,
                (t.clientY - rect.top) / rect.height - grabDY
            );
        };

        const end = (event) => {
            if (!active) return;
            event.preventDefault();
            event.stopPropagation();
            active = false;
            grabDX = 0; grabDY = 0;
            marker.classList.remove('aiming');
            // One move on release, not sixty during, and only over the
            // picture. This is what makes hover states appear next frame.
            const point = this.aimOnScreen();
            if (point) this.movePointer(point);
        };

        marker.addEventListener('touchstart', begin, { passive: false });
        marker.addEventListener('touchmove', move, { passive: false });
        marker.addEventListener('touchend', end, { passive: false });
        marker.addEventListener('touchcancel', end, { passive: false });
        marker.addEventListener('mousedown', begin);
        window.addEventListener('mousemove', move);
        window.addEventListener('mouseup', end);

        // The picture moves whenever the layout does; the marker is fixed, so
        // it has to be redrawn against the new rect.
        const redraw = () => { this.drawAim(); this.drawNumbers(); };
        window.addEventListener('resize', redraw);
        window.addEventListener('orientationchange', () => setTimeout(redraw, 200));
        document.querySelector('.content')?.addEventListener('scroll', redraw, { passive: true });
    },

    movePointer(point) {
        if (!this.baseUrl || !this.token) return Promise.resolve();
        return fetch(`${this.baseUrl}/api/tap`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ x: point.x, y: point.y, kind: 'move' }),
        }).catch(() => {});
    },

    // ── Gestures on the picture ─────────────────────────────────────────
    //
    // One finger does NOTHING here. It used to scroll, and a quick tap used
    // to zoom — but a single physical tap fires touchend AND a synthesised
    // mouseup, so the double-tap detector saw two taps and zoomed on every
    // single tap. One finger is now reserved for dragging the pointer, which
    // has its own handler on the marker itself.
    //
    // Two fingers: pinch zooms the picture, moving them together scrolls the
    // Mac — both axes, because sideways scroll is back/forward in a browser
    // and panning in Maps. Which one you meant is decided once, on the first
    // real movement, so a pinch never turns into a scroll halfway.
    //
    // Four fingers: the Mac's own four-finger gestures, via the keyboard
    // shortcuts they map to.
    installScreenGestures() {
        const stage = document.getElementById('screenStage');
        if (!stage || stage.dataset.gestures) return;
        stage.dataset.gestures = '1';

        let mode = null;              // null | 'pinch' | 'scroll' | 'four'
        let startDistance = 0, startScale = 1;
        let last = null;              // last centroid
        let startCentroid = null;
        let pinchOrigin = null;

        const centroid = (touches) => {
            let x = 0, y = 0;
            for (const t of touches) { x += t.clientX; y += t.clientY; }
            return { x: x / touches.length, y: y / touches.length };
        };
        const spread = (touches) =>
            Math.hypot(touches[0].clientX - touches[1].clientX,
                       touches[0].clientY - touches[1].clientY);

        stage.addEventListener('touchstart', (e) => {
            mode = null;
            last = null;
            if (e.touches.length === 2) {
                startDistance = spread(e.touches);
                startScale = this.screenScale;
                const c = centroid(e.touches);
                // Anchor the zoom on the PICTURE, not on the frame around it.
                // At rest the two are the same box, so this looked fine. Once
                // magnified they have nothing to do with each other: the frame
                // stays 350x228 while the image grows to 870x565 and hangs off
                // the left edge, so a pinch in the middle of what you can see
                // measures 0.05,0.95 against the frame — the far corner. The
                // second pinch is the one that matters, because that is how you
                // home in on a small button.
                //
                // The anchor is only chosen when the picture is at rest.
                // transform-origin is the point scale pivots on, so moving it
                // while already magnified slides the content by (scale - 1)
                // times however far the anchor moved. One anchor per zoom-in:
                // pinch back out to 1x and the next pinch picks a fresh one.
                const rect = this.imageRect();
                pinchOrigin = (rect && this.screenScale === 1)
                    ? { x: (c.x - rect.left) / rect.width, y: (c.y - rect.top) / rect.height }
                    : null;   // null = setZoom keeps the anchor already in use
                last = c;
                startCentroid = c;
            } else if (e.touches.length >= 4) {
                mode = 'four';
                startCentroid = centroid(e.touches);
            }
        }, { passive: true });

        stage.addEventListener('touchmove', (e) => {
            if (e.touches.length === 2) {
                e.preventDefault();
                const c = centroid(e.touches);
                const distance = spread(e.touches);

                if (mode === null) {
                    // Whichever crosses its threshold first wins the gesture.
                    const spreadChange = Math.abs(distance - startDistance);
                    const moved = Math.hypot(c.x - startCentroid.x, c.y - startCentroid.y);
                    if (spreadChange > 14) mode = 'pinch';
                    else if (moved > 12) mode = 'scroll';
                    else return;
                }

                if (mode === 'pinch') {
                    this.setZoom(startScale * (distance / startDistance), pinchOrigin);
                } else if (mode === 'scroll' && last) {
                    const rect = this.imageRect();
                    if (rect) {
                        // Normalised against the picture so a swipe moves the
                        // Mac about as far as it moves under your fingers.
                        const dx = (c.x - last.x) / rect.width;
                        const dy = (c.y - last.y) / rect.height;
                        const at = {
                            x: Math.min(1, Math.max(0, (c.x - rect.left) / rect.width)),
                            y: Math.min(1, Math.max(0, (c.y - rect.top) / rect.height)),
                        };
                        this.sendSwipe(at, dx, dy);
                    }
                    last = c;
                }
            } else if (e.touches.length >= 4) {
                e.preventDefault();
                mode = 'four';
                // Track the hand's centre. Reading one finger's position at
                // the end and comparing it to where the CENTRE started gives
                // that finger's offset from the middle as if it were travel:
                // a wide hand swiping straight up reads as a diagonal.
                last = centroid(e.touches);
            }
        }, { passive: false });

        const finish = () => {
            if (mode === 'four' && startCentroid && last) {
                const dx = last.x - startCentroid.x;
                const dy = last.y - startCentroid.y;
                if (Math.hypot(dx, dy) > 50) this.fourFingerSwipe(dx, dy);
            }
            if (this.screenScale < 1.05 && this.screenScale !== 1) this.setZoom(1);
            mode = null; last = null; startCentroid = null;
        };
        stage.addEventListener('touchend', finish);
        stage.addEventListener('touchcancel', finish);
    },

    // The Mac's four-finger gestures are also keyboard shortcuts, and the
    // Phrasebook already knows every one of them — so this needs no new
    // endpoint and no new Swift.
    fourFingerSwipe(dx, dy) {
        if (!this.baseUrl || !this.token) return;
        const horizontal = Math.abs(dx) > Math.abs(dy);
        const command = horizontal
            ? (dx > 0 ? 'previous space' : 'next space')
            : (dy < 0 ? 'mission control' : 'show desktop');
        this.toast(command.charAt(0).toUpperCase() + command.slice(1));
        fetch(`${this.baseUrl}/api/command`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ command }),
        }).then(() => this.refreshScreenSoon()).catch(() => {});
    },

    // One place owns the zoom, so pinch and everything else agree.
    //
    // The scale goes on the IMAGE, not on the frame around it. Scaling the
    // frame made the frame itself grow — transforms do not affect layout, so
    // at 2.6x it simply covered the header and the voice section. Scaling the
    // image inside a frame that clips means zooming magnifies the picture and
    // nothing else on the page moves at all.
    setZoom(scale, origin) {
        const img = document.getElementById('screenImage');
        if (!img) return;
        this.screenScale = Math.min(5, Math.max(1, scale));
        if (origin) {
            this.zoomOriginX = Math.min(100, Math.max(0, origin.x * 100));
            this.zoomOriginY = Math.min(100, Math.max(0, origin.y * 100));
        }
        if (this.screenScale === 1) { this.zoomOriginX = 50; this.zoomOriginY = 50; }
        img.style.transformOrigin = `${this.zoomOriginX}% ${this.zoomOriginY}%`;
        img.style.transform = `scale(${this.screenScale})`;
        // Zooming can push the aimed pixel outside what the frame shows. That
        // is drawAim's problem to present, not ours to silently fix by moving
        // the aim somewhere else.
        this.drawAim();
        // The badges live on the picture too, so they move with it.
        this.drawNumbers();
    },

    // Long press an approval to remember the answer. Keeping four buttons on
    // every card made the common case (yes / no) slower for the sake of the
    // rare one.
    openApprovalSheet(approval) {
        this.sheetApproval = approval;
        document.getElementById('approvalSheetTitle').textContent =
            `Remember “${approval.originatingApp?.name || approval.title}”?`;
        this.openSheet('approvalSheet');
    },

    applyRememberedChoice(mode) {
        const approval = this.sheetApproval;
        this.closeSheet('approvalSheet');
        if (!approval) return;
        const id = approval.originatingApp?.bundleIdentifier;
        // "unknown.bundle" is what the Mac uses when it could not read
        // one, so remembering against it would quietly apply to every
        // app in that state — and returning in silence tells the person
        // nothing at all about why their choice did nothing.
        if (!id || id === 'unknown.bundle') {
            this.toast('Your Mac could not tell which app this is, so there is nothing to remember', true);
            return;
        }
        // The policy is written AFTER the gate below, not before it.
        // Writing it here meant reading "Are you sure?" and tapping
        // Cancel still left the app permanently on the always list.
        const remember = () => this.setPolicy({ id, mode });
        // Answer the card too, but only with a button it actually has.
        //
        // A `deny`/`once` pair exists on an agent prompt. On an app
        // dialog the option id IS the button's label — "Leave",
        // "Cancel", "Don't Save" — so posting "deny" asked the Mac to
        // press a button that is not there, and the sheet offered an
        // action that could never work on the commonest kind of card.
        // A TCC card has no pressable option at all.
        const { allow, deny } = this.resolveIntents(approval);
        const wanted = mode === 'never' ? deny : (mode === 'always' ? allow : null);
        if (!wanted) {
            // A TCC prompt is not "remembered" in any useful sense: the
            // Mac skips the never-rule for those and always escalates,
            // so saying otherwise promises something that will not
            // happen. Say what is actually true.
            if (approval.handoffOnly) {
                this.toast('macOS permission prompts always ask — this one has to be answered at the Mac', true);
            } else {
                remember();
                this.toast(mode === 'auto'
                    ? 'Allowly will decide this app from now on'
                    : 'Remembered. Answer this one on the card.');
            }
            return;
        }
        // A high-risk option goes through the SAME confirmation the card
        // tap and the spoken answer do.
        //
        // This path pressed it outright — and the daemon runs a decision
        // from a card with `answeredCard: true`, which deliberately
        // skips the never-press-by-yourself list on the grounds that
        // "the person read the button's name and, for a high-risk
        // option, answered Are you sure as well". Neither was true here:
        // the sheet's buttons say "Always allow this app", which reads
        // as a preference, and it never names the button it is about to
        // press. So "Always allow" on a dialog offering "Allow" pressed
        // a high-risk grant with no gate at either end.
        if ((wanted.riskLevel || 'low') === 'high') {
            // Handed IN, not assigned around the call. Assigning it
            // first and calling second looked right and was dead: the
            // first thing `showConfirmation` does is clear the field, to
            // stop a re-entered confirmation carrying the previous one's
            // policy write. So "Always allow this app" and "Never allow
            // this app" both answered the dialog and remembered
            // nothing — on ["Allow", "Don't Allow"], where BOTH options
            // are high risk, which is the commonest dialog on macOS.
            // Silent, and one of the two directions is a standing DENY
            // the person believed they had set.
            this.showConfirmation(approval, wanted, approval.id, wanted.id, remember);
            return;
        }
        remember();
        this.submitDecision(approval.id, wanted.id);
    },

    // Pinch to zoom the screen view. The overlay is positioned in percentages
    // inside the same element, so scaling the container keeps every number
    // registered to the pixel it belongs to.
    // Permissions
    loadPolicy() {
        if (!this.baseUrl || !this.token) return;
        // Every row this paints carries a live handler that writes a
        // policy back. A response landing after an unpair repainted the
        // old Mac's exception list, and because bundle ids are the same
        // on both machines, a tap wrote that mode to the NEW Mac and
        // succeeded rather than failing.
        const era = this.era();
        fetch(`${this.baseUrl}/api/policy?t=${Date.now()}`, {
            cache: 'no-store',
            headers: { 'Authorization': `Bearer ${this.token}` },
        })
            .then(r => r.json())
            .then(policy => { if (this.sameEra(era)) this.renderPolicy(policy); })
            .catch(err => console.error('Failed to load policy:', err));
    },

    renderPolicy(policy) {
        // Say it where it can be seen. A rejected notification is
        // invisible by construction — "no push arrived" and "nothing
        // happened" look identical from the phone — and jev spent
        // months having every single send refused by Apple with one
        // line in a log file as the only trace.
        const warning = document.getElementById('pushWarning');
        if (warning) {
            if (policy.pushError) {
                warning.textContent =
                    `Notifications are not arriving: ${policy.pushError}. `
                    + 'Your Mac is still working — open this app to see what is waiting.';
                warning.classList.remove('hidden');
            } else {
                warning.textContent = '';
                warning.classList.add('hidden');
            }
        }
        // …and on the banner, because the settings sheet is two taps and
        // a scroll away. Every LESSER push problem — permission not
        // granted, not installed to the Home Screen — already uses that
        // banner; the one where the Mac is refusing every send was the
        // one buried. It is also the one the person cannot detect,
        // since a notification that never arrives looks exactly like
        // nothing having happened.
        if (policy.pushError) {
            this.showPushBanner(`Notifications are not arriving: ${policy.pushError}`);
        }

        const globalEl = document.getElementById('policyGlobal');
        globalEl.innerHTML = '';
        (policy.globalOptions || []).forEach(option => {
            const button = document.createElement('button');
            button.className = 'policy-option' + (option.id === policy.global ? ' selected' : '');
            button.textContent = option.label;
            button.addEventListener('click', () => this.setPolicy({ global: option.id }));
            globalEl.appendChild(button);
        });

        // The same list is a whitelist or a blacklist depending on the default,
        // so say which it is rather than leaving it to be inferred.
        const hint = {
            denyAll: 'Everything is blocked except these.',
            allowAll: 'Everything is allowed except the ones set to never.',
            // What it can actually press, not what the name suggests.
            // Jev only ever presses an option rated low risk — Cancel,
            // Deny, Don't Allow, Not Now, Close. Anything that grants,
            // sends, deletes or discards comes to you, whatever the
            // decider says, because those are the ones you are asked to
            // confirm even when you tap them yourself.
            auto: 'Allowly answers the safe ones itself (Cancel, Deny, Not Now) and asks you about the rest.',
            ask: 'Allowly asks you about anything not listed here.',
        }[policy.global] || '';
        document.getElementById('policyExceptionsHint').textContent = hint;

        const list = document.getElementById('policyEntries');
        list.innerHTML = '';
        if (!(policy.entries || []).length) {
            list.innerHTML = '<div class="empty-state"><p>No exceptions yet</p></div>';
        }
        (policy.entries || []).forEach(entry => {
            const row = document.createElement('div');
            row.className = 'policy-row';

            const name = document.createElement('span');
            name.className = 'name';
            name.textContent = entry.name;
            row.appendChild(name);

            const select = document.createElement('select');
            [['always', 'Always'], ['auto', 'Ask Allowly'], ['never', 'Never']].forEach(([value, label]) => {
                const option = document.createElement('option');
                option.value = value;
                option.textContent = label;
                option.selected = value === entry.mode;
                select.appendChild(option);
            });
            select.addEventListener('change', () => this.setPolicy({ id: entry.id, mode: select.value }));
            row.appendChild(select);

            const forget = document.createElement('button');
            forget.className = 'forget';
            forget.textContent = 'Forget';
            forget.addEventListener('click', () => this.setPolicy({ id: entry.id }));
            row.appendChild(forget);

            list.appendChild(row);
        });
    },

    setPolicy(change) {
        if (!this.baseUrl || !this.token) return;
        fetch(`${this.baseUrl}/api/policy`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify(change),
        })
            .then(() => this.loadPolicy())
            .catch(err => console.error('Failed to set policy:', err));
    },

    // Fetch the current pending list from the Mac.
    loadApprovals() {
        if (!this.baseUrl || !this.token) return;
        // Which Mac this answer belongs to. Unpairing mid-flight used to
        // let the response land after the clear and put the old Mac's
        // card back — invisible while the main screen was hidden, and
        // then right there with live buttons the moment you paired with
        // a second Mac. A tap would post a decision to the new Mac for
        // an id it had never heard of.
        const era = this.era();
        fetch(`${this.baseUrl}/api/pending?t=${Date.now()}`, {
            cache: 'no-store',
            headers: { 'Authorization': `Bearer ${this.token}` },
        })
            // NOT `r.ok ? r.json() : []`. Turning an error into an empty
            // list wiped every card and set `approvalsLoaded`, so a
            // daemon restart that minted a new token, or one 502 from
            // `tailscale serve`, made the phone say "Nothing waiting"
            // while the Mac's apps sat blocked on prompts it still had.
            // An empty list and an unreadable Mac are different answers.
            .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
            .then(list => {
                if (!this.sameEra(era)) return;
                this.approvalsLoaded = true;
                this.state.approvals.clear();
                (list || []).forEach(a => this.state.approvals.set(a.id, a));
                this.renderApprovals();
            })
            .catch(err => console.error('Failed to load approvals:', err));
    },

    handleNewApproval(approval) {
        this.state.approvals.set(approval.id, approval);
        this.renderApprovals();
    },

    // The one card that is actually on screen.
    //
    // There is exactly one selector for this, because there used to be
    // two. The renderer took the OLDEST; the voice path took whatever
    // `Map.values()` yielded first, which is the order /api/pending
    // returned them in — Swift dictionary order, arbitrary and reseeded
    // per process. With two cards pending you could be looking at a
    // "Leave site?" prompt, say "approve", and have jev allow a shell
    // command on the card underneath it. The toast would name the one you
    // could not see, and the one you were reading would still be there.
    visibleApproval() {
        // The one the notification was about, if it is still waiting.
        // Cleared once shown, so it does not pin the view forever.
        if (this.focusApproval) {
            const wanted = this.state.approvals.get(this.focusApproval);
            if (wanted) return wanted;
            // Gone. Say so rather than quietly showing a different card
            // under the heading the notification put in your head — the
            // card you are about to look at is not the one you tapped.
            // Only once the full list has actually been fetched. A live
            // `approval` push can beat /api/pending on a cold start, so
            // rendering from a one-card map would throw the pin away and
            // announce it, for a card that is still perfectly pending.
            if (this.approvalsLoaded) {
                this.focusApproval = null;
                if (this.state.approvals.size) {
                    this.toast('That one is no longer waiting — this is something else', true);
                }
            } else if (this.state.approvals.size) {
                // The list has not loaded yet, so the pin is KEPT — but
                // what is on screen is still not the card the
                // notification named, and saying nothing is how a
                // reflexive Allow answers the wrong thing.
                this.toast('Still finding the one you tapped — this is something else', true);
            }
        }
        // Tie-broken by id, because the timestamp is not a total order:
        // the Mac encodes ISO8601 to whole SECONDS, so two cards raised
        // in the same second compare equal and the winner falls back to
        // Map insertion order — which is Swift dictionary order and
        // reshuffles as the store is mutated. The card on screen could
        // then swap between polls, which is the bug this selector exists
        // to prevent, arriving one layer down.
        return [...this.state.approvals.values()]
            .sort((a, b) => (new Date(a.timestamp) - new Date(b.timestamp))
                         || String(a.id).localeCompare(String(b.id)))[0];
    },

    handleResolvedApproval(id) {
        // If the Mac withdrew the very card a modal or sheet is asking
        // about, that question no longer has an answer.
        if (this.confirmData && this.confirmData.requestId === id) {
            this.closeConfirm();
            this.toast('Your Mac took that one back', true);
        }
        if (this.sheetApproval && this.sheetApproval.id === id) {
            this.sheetApproval = null;
            this.closeSheet('approvalSheet');
        }
        // Only redraw if this was ours. `renderApprovals` empties the list
        // and rebuilds every card from scratch, so a `resolved` for an id
        // this phone never held would tear down the card you are looking
        // at — and if your finger was mid-tap on an option, the click never
        // lands, because the button it was on no longer exists. The Mac now
        // announces reaped and unknown ids too, so this arrives more often.
        if (!this.state.approvals.delete(id)) return;
        this.renderApprovals();
    },

    // Approval rendering
    renderApprovals() {
        const list = document.getElementById('approvalsList');
        const count = this.state.approvals.size;

        // The count rides next to the heading so the number is readable
        // without scrolling the list.
        // The heading is visually hidden, so this is purely what a screen
        // reader hears. Never toggled with .hidden: display:none would pull
        // the live region out of the accessibility tree and silence it.
        const badge = document.getElementById('approvalsCount');
        if (badge) {
            badge.textContent = String(count);
            badge.setAttribute('aria-label',
                count === 0
                    ? (this.approvalsLoaded ? 'Nothing waiting' : 'Checking with your Mac')
                    : `${count} waiting for you`);
        }

        if (count === 0) {
            // Notifications that are not there draw nothing at all.
            list.innerHTML = '';
            return;
        }

        // ONE card, the oldest. Everything else waits its turn.
        //
        // A stack makes the spoken shortcut ambiguous: "approve" would have
        // to pick one for you. With a single card there is nothing to choose
        // between — what you see is what you answer — and the Mac screen gets
        // most of its space back.
        list.innerHTML = '';
        const approval = this.visibleApproval();
        const card = this.createApprovalCard(approval);
        list.appendChild(card);

        // Say how many are behind it, so a queue is never silently hidden.
        if (count > 1) {
            const more = document.createElement('p');
            more.className = 'queue-note';
            more.textContent = `${count - 1} more after this`;
            list.appendChild(more);
        }
    },

    // Everything on a card is text somebody else wrote.
    //
    // The title, the body, the app's name and every button label come from
    // a dialog on the Mac — and for a Claude Code prompt, from the tool
    // call's own arguments, which an injected agent session controls. They
    // were being interpolated into `innerHTML`, so `<img src=x onerror=…>`
    // in a tool argument ran JavaScript inside the paired app, which holds
    // the bearer token for full remote control of the Mac. `drawNumbers`
    // already treats a window title as untrusted text; this did not.
    esc(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    },

    createApprovalCard(approval) {
        const card = document.createElement('div');
        card.className = 'approval-card';
        if (approval.handoffOnly) {
            card.classList.add('tcc');
        }
        card.id = `approval-${approval.id}`;

        const { label: kindLabel, cls: kindClass } = this.getKind(approval.kind);
        const isTCC = approval.handoffOnly;

        let optionsHTML = '';
        if (isTCC) {
            // Deliberately no button. macOS tags every click with where it came
            // from, and a permission sheet honours only events from real
            // hardware — so nothing software can send will press this, jev and
            // Screen Sharing included. A button that does nothing is worse than
            // no button: you would tap it and not know what failed.
            optionsHTML = `
                <div class="approval-tcc-notice">
                    <p><strong>You have to press this one at the Mac.</strong>
                    It is a macOS privacy prompt, and Apple only accepts a press
                    from real hardware. No remote tool can answer it — not Allowly,
                    not Screen Sharing.</p>
                    <p class="approval-tcc-advice">Grant it once in System Settings
                    on your Mac and it will stop interrupting you when you are away.</p>
                </div>
            `;
        } else {
            optionsHTML = '<div class="approval-options">';
            approval.options.forEach(option => {
                const riskLevel = option.riskLevel || 'low';
                optionsHTML += `
                    <button class="option-btn risk-${this.esc(riskLevel)}" data-request-id="${this.esc(approval.id)}" data-option-id="${this.esc(option.id)}" data-risk="${this.esc(riskLevel)}">
                        <span>${this.esc(option.label)}</span>
                        <span class="risk-indicator">${this.esc(riskLevel)}</span>
                    </button>
                `;
            });
            optionsHTML += '</div>';
        }

        // A data: URL and nothing else. Anything with a scheme jev did not
        // put there is not a screenshot of your Mac.
        const shot = String(approval.screenshotReference || '');
        const screenshot = /^data:image\/(png|jpeg|jpg|webp);base64,[A-Za-z0-9+/=]+$/.test(shot)
            ? `<img class="approval-screenshot" src="${this.esc(shot)}" alt="Screenshot">` : '';

        const timestamp = new Date(approval.timestamp).toLocaleTimeString();

        card.innerHTML = `
            <div class="approval-header">
                <div class="approval-app-info">
                    <div class="approval-app-name">${this.esc(approval.originatingApp && approval.originatingApp.name)}</div>
                    <div class="approval-timestamp">${this.esc(timestamp)}</div>
                </div>
                <span class="approval-kind-badge ${this.esc(kindClass)}">${this.esc(kindLabel)}</span>
            </div>
            <div class="approval-title">${this.esc(approval.title)}</div>
            ${approval.bodyText ? `<div class="approval-body">${this.esc(approval.bodyText)}</div>` : ''}
            ${screenshot}
            ${optionsHTML}
        `;

        if (!isTCC) {
            card.querySelectorAll('.option-btn').forEach(btn => {
                btn.addEventListener('click', (e) => {
                    e.preventDefault();
                    const requestId = btn.dataset.requestId;
                    const optionId = btn.dataset.optionId;
                    const risk = btn.dataset.risk;

                    if (risk === 'high') {
                        // Recover the option object. `option` used to be read
                        // straight from here, but it only ever existed as the
                        // parameter of the options.forEach above, whose closure
                        // has long since ended. The ReferenceError landed after
                        // preventDefault, so a high-risk tap did nothing at all:
                        // no modal, no submission, no error — you tapped, saw
                        // nothing, and tapped again.
                        const option = approval.options.find(o => o.id === optionId);
                        this.showConfirmation(approval, option, requestId, optionId);
                    } else {
                        this.submitDecision(requestId, optionId);
                    }
                });
            });
        }

        // Press and hold anywhere on the card for the remembered choices.
        let holdTimer = null;
        const startHold = () => {
            holdTimer = setTimeout(() => {
                // The card may have been torn down under the finger —
                // `renderApprovals` rebuilds the list on any `resolved`
                // — and this closure captured the old object. Opening
                // the sheet for it would let "always allow" post a
                // decision for a card that is gone.
                if (!this.state.approvals.has(approval.id)) return;
                this.openApprovalSheet(approval);
            }, 500);
        };
        const cancelHold = () => clearTimeout(holdTimer);
        card.addEventListener('touchstart', startHold, { passive: true });
        card.addEventListener('touchend', cancelHold);
        card.addEventListener('touchmove', cancelHold, { passive: true });
        card.addEventListener('mousedown', startHold);
        card.addEventListener('mouseup', cancelHold);
        card.addEventListener('mouseleave', cancelHold);

        return card;
    },

    // Which option means "go ahead", and which means "don't".
    //
    // Option ids are NOT stable: for an app dialog the id IS the button's
    // label, whatever the app happened to call it ("Save", "Don't Save",
    // "Replace"). So saying "approve" cannot be wired to a fixed id — it has
    // to read the labels and decide. Anything it is not sure about, it
    // refuses to answer, and the buttons stay the only way through.
    AFFIRM: ['allow', 'always allow', 'approve', 'accept', 'yes', 'ok', 'okay',
             'continue', 'proceed', 'save', 'trust', 'grant', 'once', 'open'],
    REFUSE: ['deny', 'reject', 'refuse', 'decline', 'cancel', 'block', 'stop',
             'quit', 'discard', 'ignore', 'dismiss', 'later', 'not now',
             // Removing elimination exposed which real refusals it had
             // been covering for. "Not Now" matched nothing: "not" is
             // not in NEGATE, and the word-boundary test correctly
             // refuses to see "no" inside it.
             'no thanks', 'skip for now'],
    // A negation beats whatever follows it. "Don't Allow" contains "allow",
    // and the whole meaning of the button is the word in front of it — this
    // is the single most common consent dialog on macOS, so getting it
    // backwards would be the worst possible failure of the gesture.
    NEGATE: ["don't", 'do not', 'never', 'no'],

    // Whole words only. A plain substring test matches "no" inside "Notes"
    // and "ok" inside "Book".
    hasTerm(text, term) {
        const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        return new RegExp(`(^|[^a-z])${escaped}([^a-z]|$)`).test(text);
    },

    scoreTerms(text, terms) {
        let best = 0;
        for (const t of terms) if (this.hasTerm(text, t) && t.length > best) best = t.length;
        return best;
    },

    RISK_ORDER: { low: 0, medium: 1, high: 2 },

    // Returns { allow, deny } — either may be null when nothing is a clear
    // enough match. Never returns the same option for both.
    resolveIntents(approval) {
        if (!approval || approval.handoffOnly) return { allow: null, deny: null };
        const options = approval.options || [];
        if (!options.length) return { allow: null, deny: null };

        // A panel shows option.label so you can read what you are about to
        // send. So the test has to be on that exact string — falling back to
        // the id here made an option with an empty label "readable" and then
        // rendered a blank panel. Empty, punctuation-only and emoji-only
        // labels are never nominated for either side.
        const readable = (o) => /[a-z0-9]/i.test(o.label || '');

        const scored = options.filter(readable).map(o => {
            // The LABEL only. It is what the panel shows and what the person
            // reads before letting go; an id that disagrees with it must not
            // be able to change the meaning. Curly apostrophes are what macOS
            // actually puts in a button.
            const label = (o.label || o.id || '').toLowerCase().replace(/[\u2018\u2019]/g, "'");
            const negated = this.scoreTerms(label, this.NEGATE);
            const yes = negated ? 0 : this.scoreTerms(label, this.AFFIRM);
            const no = Math.max(negated, this.scoreTerms(label, this.REFUSE));
            return {
                option: o,
                yes, no,
                // How much of the label the matched word accounts for. This,
                // not the raw word length, is what ranks candidates.
                cover: (k) => (label.length ? k / label.length : 0),
                yesCover: label.length ? yes / label.length : 0,
                noCover: label.length ? no / label.length : 0,
                risk: this.RISK_ORDER[o.riskLevel] ?? 0,
            };
        });

        // A button has to be mostly the word, not merely contain it. Without
        // this, "Quit without saving and discard everything" beat plain
        // "Cancel" for the refuse slot — it matched a longer word — so saying
        // "cancel", which should always be the safe word, would have thrown
        // the work away.
        // Low enough for "Remind Me Later".
        //
        // At 0.34 a five-letter refusal inside a fifteen-character
        // button scored 0.333 and lost, so the standard macOS update
        // sheet — "Install Now" / "Remind Me Later" — offered neither a
        // spoken yes nor a spoken no. The floor exists to stop a word
        // buried in a sentence winning; a third of a short button label
        // is not that.
        const FLOOR = 0.3;

        const pick = (key, other) => {
            const coverKey = key === 'yes' ? 'yesCover' : 'noCover';
            const hits = scored.filter(x => x[key] > 0 && x[key] > x[other] && x[coverKey] >= FLOOR);
            if (!hits.length) return null;
            // Best coverage first; on a tie take the most cautious option, so
            // "Allow once" wins over "Allow for this project" rather than the
            // pair cancelling out. Both are affirmative — the question is only
            // which one a spoken "approve" commits you to, and it is the
            // smaller.
            hits.sort((a, b) => (b[coverKey] - a[coverKey]) || (a.risk - b.risk));
            if (hits.length > 1 && hits[0][coverKey] === hits[1][coverKey]
                && hits[0].risk === hits[1].risk) {
                return null;   // genuinely indistinguishable
            }
            return hits[0].option;
        };

        let allow = pick('yes', 'no');
        let deny = pick('no', 'yes');
        // Elimination fills the REFUSE side only, and never the affirmative.
        //
        // This asymmetry is the most important rule here. Inferring "the other
        // button must be the approval" is how saying "yes" came to mean
        // Empty Trash, Shut Down, Format and Unpair: none of those words
        // is recognised, they were simply the option that was not "Cancel",
        // and macOS rates them low risk so they would have gone straight
        // through with no confirmation. Approving now demands a positive match
        // against AFFIRM. Refusing by elimination stays, because its worst
        // case is cancelling something you wanted, which you can redo.
        // …and elimination is GONE.
        //
        // The rule was "on a two-button dialog, the one that is not the
        // approval must be the refusal". Every genuine refusal already
        // matches REFUSE or NEGATE and is found by `pick` above —
        // Cancel, Deny, Don't Allow, Not Now, Stop. So elimination only
        // ever fired when the other button was something ELSE, which is
        // exactly when it must not: it made "Save As…" the deny on
        // ["Save", "Save As…"], "Learn More" on ["Allow", "Learn More"],
        // and "Move to Trash" on ["Open", "Move to Trash"]. Saying "no"
        // then pressed a button that does something, and the phone
        // toasted that it had sent it.
        //
        // Narrowing it twice did not help, because the premise is
        // wrong. With it gone, such a dialog simply offers no spoken
        // "no" — you read the buttons and tap one, which is the honest
        // answer for a dialog whose options are not yes and no.
        if (allow && deny && allow === deny) return { allow: null, deny: null };
        // Two buttons reading the same word on opposite panels is a coin
        // toss dressed up as a choice.
        if (allow && deny && (allow.label || '') === (deny.label || '')) {
            return { allow: null, deny: null };
        }
        return { allow: allow || null, deny: deny || null };
    },

    // One table, four kinds. The label and the CSS class were previously
    // derived in two different places — the label from a map here, the class
    // from a camelCase-to-kebab regex at the call site — so they drifted:
    // the regex produced `agent-tool-prompt` while the stylesheet only ever
    // had `.agent`. Every badge in the app missed and fell through to plain
    // blue. Keeping both in one place makes that impossible to repeat.
    KINDS: {
        agentToolPrompt: { label: 'Agent', cls: 'agent-tool-prompt' },
        appDialog: { label: 'Dialog', cls: 'app-dialog' },
        tccConsent: { label: 'System', cls: 'tcc-consent' },
        spokenCommand: { label: 'Voice', cls: 'spoken-command' },
    },

    getKind(kind) {
        return this.KINDS[kind] || { label: kind, cls: '' };
    },

    getKindLabel(kind) {
        return this.getKind(kind).label;
    },

    // Decision submission
    submitDecision(requestId, optionId) {
        // Look the label up before the card goes, so the confirmation can name
        // what was sent rather than saying a bare "Done".
        const approval = this.state.approvals.get(requestId);
        const chosen = approval && (approval.options || []).find(o => o.id === optionId);

        this.postDecision({
            requestId,
            optionId,
            nonce: this.generateNonce(),
        }, chosen && chosen.label);
    },

    showConfirmation(approval, option, requestId, optionId, remember = null) {
        // A second confirmation replaces the first entirely.
        //
        // Every DISMISSAL path cleared `pendingRemember`; re-entry did
        // not. You could arm "always allow this app", change your mind,
        // and the modal would swap to the other option while still
        // carrying the always-allow write — so denying the dialog put
        // the app on the always list for good.
        //
        // (The original note explained this in terms of BOTH options on
        // an ["Allow", "Don't Allow"] sheet being high risk, because
        // "don't allow" contains "allow". That stopped being true when
        // the risk table learned that a negation inverts the word after
        // it; the bug and the fix are unchanged, the reasoning was
        // about to mislead the next reader.)
        // Replaced, not merely cleared. Every caller that is not arming a
        // policy write passes nothing and gets the old clearing
        // behaviour; the one that is arming one passes it here, where it
        // cannot be wiped by the line that exists to protect it.
        this.pendingRemember = remember || null;
        this.confirmData = { requestId, optionId };

        // Name the actual action on the button. "Yes" next to "Cancel" makes
        // you re-read the sentence to work out which one does the thing;
        // a button that says "Deny" does not.
        const label = (option && option.label) || 'this';
        const app = approval && approval.originatingApp && approval.originatingApp.name;

        document.getElementById('confirmTitle').textContent = 'Are you sure?';
        document.getElementById('confirmMessage').textContent =
            `“${label}” is marked high risk${app ? ` for ${app}` : ''}. It happens on your Mac straight away.`;
        document.getElementById('confirmYes').textContent = label;

        document.getElementById('confirmModal').classList.remove('hidden');
    },

    submitConfirmedDecision() {
        // Only now is the "remember this app" part real, if one was
        // waiting on this confirmation.
        if (this.pendingRemember) { this.pendingRemember(); this.pendingRemember = null; }
        if (this.confirmData) {
            this.submitDecision(this.confirmData.requestId, this.confirmData.optionId);
            this.confirmData = null;
        }
        this.closeConfirm();
    },

    closeConfirm() {
        // Forget what it was about. `confirmData` was only cleared on
        // submit, so dismissing the modal left it armed — and if the
        // Mac withdrew the request in the meantime, the next confirm
        // posted a decision for a card that no longer exists.
        this.confirmData = null;
        this.pendingRemember = null;
        document.getElementById('confirmModal').classList.add('hidden');
    },

    postDecision(decision, label) {
        if (!this.baseUrl || !this.token) return;
        const era = this.era();
        fetch(`${this.baseUrl}/api/decide`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${this.token}`,
            },
            body: JSON.stringify(decision),
        })
            .then(r => r.json())
            .then(result => {
                if (!this.sameEra(era)) return;
                console.log('Decision submitted:', result);
                // A 202 is not a yes. /api/decide answers 202 with
                // {"status":"failed"} for a replayed nonce, an id it has
                // never heard of, and a dialog that closed on the Mac — and
                // saying "Sent “Allow” to your Mac" to all three made the
                // replay guard invisible in exactly the case it exists for.
                if (result && result.status === 'failed') {
                    this.toast(result.reason || 'Your Mac would not take that', true);
                    return;
                }
                // …and "ok" is not a yes either, when the Mac has told us
                // in so many words that nothing happened. The daemon
                // presses the button, waits, and checks whether the
                // dialog went away; a macOS permission prompt accepts
                // the press, ignores it, and leaves the sheet up. That
                // answer came back as `landed: false` with a sentence
                // explaining it — and this line threw the sentence away
                // and toasted "Sent", which is the one lie the check was
                // added to stop telling. The card stays up in this case,
                // so the toast has to say why.
                if (result && result.landed === false) {
                    this.toast(result.reason || 'Pressed it, but the dialog is still on your Mac', true);
                    return;
                }
                // The card disappears on the 'resolved' push, which on its own
                // is indistinguishable from a tap that never registered.
                this.toast(label ? `Sent “${label}” to your Mac` : 'Sent to your Mac');
            })
            .catch(err => {
                console.error('Failed to submit decision:', err);
                this.toast('Could not reach your Mac — try again', true);
            });
    },

    // Nonce generation
    generateNonce() {
        const timestamp = Date.now();
        const random = Math.random().toString(36).substring(2, 8);
        return `${timestamp}-${random}`;
    },

    // Push-to-talk recording
    /// A container Apple Speech can actually open.
    ///
    /// Prefer MP4/AAC: the Mac transcribes with Apple Speech, which
    /// cannot open a WebM/Opus container at all — a browser happily
    /// records one and every transcription then fails with "Cannot
    /// Open". Shared, because push-to-talk negotiated this and
    /// hands-free did not, so on Chromium the button worked and
    /// hands-free silently did not.
    recorderOptions() {
        for (const candidate of ['audio/mp4', 'audio/aac', 'audio/mpeg', 'audio/webm']) {
            if (MediaRecorder.isTypeSupported(candidate)) return { mimeType: candidate };
        }
        return {};
    },

    async startRecording() {
        // Same shape as the hands-free guard: an await on the microphone
        // permission, and nothing to send the recording to afterwards.
        if (!this.baseUrl || !this.token) return;
        // Refuse before opening the microphone at all.
        if (this.secretFieldArmed()) {
            this.toast('Type a password — never say it out loud', true);
            return;
        }
        const era = this.era();
        if (this.state.recording) return;

        try {
            // Request user permission for audio
            const stream = await navigator.mediaDevices.getUserMedia({
                audio: {
                    echoCancellation: true,
                    noiseSuppression: true,
                },
                video: false,
            });
            // Unpaired mid-permission. Hand the microphone back.
            if (!this.sameEra(era)) {
                stream.getTracks().forEach(t => t.stop());
                return;
            }

            // Use appropriate MIME type for iOS Safari
            this.state.mediaRecorder = new MediaRecorder(stream, this.recorderOptions());
            this.state.audioChunks = [];
            this.state.recording = true;
            this.state.recordingStartTime = Date.now();

            this.state.mediaRecorder.addEventListener('dataavailable', (event) => {
                if (event.data.size > 0) {
                    this.state.audioChunks.push(event.data);
                }
            });

            this.state.mediaRecorder.addEventListener('stop', () => {
                this.handleRecordingComplete();
            });

            this.state.mediaRecorder.start();
            this.updateRecordingUI();

        } catch (error) {
            console.error('Failed to start recording:', error);
            this.toast('No microphone — check Safari\u2019s permissions', true);
        }
    },

    stopRecording() {
        if (!this.state.recording || !this.state.mediaRecorder) return;

        this.state.recording = false;
        this.state.mediaRecorder.stop();
        this.state.mediaRecorder.stream.getTracks().forEach(track => track.stop());
        this.updateRecordingUI();
    },

    updateRecordingUI() {
        const statusEl = document.getElementById('recordingStatus');
        const timeEl = document.getElementById('recordingTime');

        if (this.state.recording) {
            statusEl.classList.remove('hidden');
            const interval = setInterval(() => {
                if (!this.state.recording) {
                    clearInterval(interval);
                    return;
                }
                const elapsed = Math.floor((Date.now() - this.state.recordingStartTime) / 1000);
                const minutes = Math.floor(elapsed / 60);
                const seconds = elapsed % 60;
                timeEl.textContent = `${minutes}:${seconds.toString().padStart(2, '0')}`;
            }, 100);
        } else {
            statusEl.classList.add('hidden');
        }
    },

    handleRecordingComplete() {
        if (this.state.audioChunks.length === 0) {
            console.warn('No audio data recorded');
            return;
        }

        // Label the blob with what was actually recorded, not a guess.
        const recordedType = (this.state.mediaRecorder && this.state.mediaRecorder.mimeType)
            || 'audio/mp4';
        const audioBlob = new Blob(this.state.audioChunks, { type: recordedType });
        this.uploadAudio(audioBlob);

        this.state.audioChunks = [];
        this.state.mediaRecorder = null;
    },

    /// Is the field waiting for dictation one that must never be spoken?
    ///
    /// Only true while the form is actually on screen. `focusedField`
    /// outlives the sheet, and keying on it alone meant that once you
    /// had armed a password box, push-to-talk refused for the rest of
    /// the session — the app's main input, dead.
    secretFieldArmed() {
        // Two sheets can be waiting for a secret, and the guard only knew
        // about one. `promptForInput(field, secret)` opens the OTHER one,
        // headed "Enter the password", under a line promising the value
        // is "never spoken, never logged" — while hands-free sat there
        // recording the room. Saying the password out loud uploaded it,
        // Apple transcribed it, `SpeechRepair` could send the readings to
        // the model, and it landed in the visible transcript history.
        const input = document.getElementById('inputSheet');
        const typeSecret = document.getElementById('typeSecret');
        if (input && !input.classList.contains('hidden')
            && typeSecret && typeSecret.checked) return true;

        const sheet = document.getElementById('formSheet');
        if (!sheet || sheet.classList.contains('hidden')) return false;
        const armed = this.focusedField && this.specFields && this.specFields[this.focusedField];
        return !!(armed && armed.secret);
    },

    uploadAudio(blob) {
        // The refusal lives HERE, where the audio leaves the phone,
        // because there are two doors and the guard was only on one.
        //
        // Push-to-talk goes through `startRecording`; hands-free calls
        // this directly from the recorder's `onstop`. So with hands-free
        // on — and it is sticky across launches — arming a password box
        // and saying it still uploaded the audio, and the Mac
        // transcribed it AND ran it as a command, which sends the words
        // to the model. `index.html` promises in so many words that
        // passwords are "never spoken, transcribed or logged".
        if (this.secretFieldArmed()) {
            this.toast('Type a password — never say it out loud', true);
            return;
        }
        // The one continuation that can ACT rather than repaint:
        // `pressNumber` taps, `answerByVoice` submits a decision. A
        // response for the old Mac landing after a re-pair would answer
        // the new Mac's card with words spoken to a different machine.
        if (!this.baseUrl || !this.token) return;
        const era = this.era();
        const formData = new FormData();
        const ext = (blob.type || '').includes('webm') ? 'webm'
            : (blob.type || '').includes('mpeg') ? 'mp3' : 'm4a';
        formData.append('audio', blob, `recording.${ext}`);

        document.getElementById('voiceResult').classList.add('hidden');

        // Who owns a spoken number this time, decided BEFORE the Mac
        // hears it.
        //
        // Both ends were claiming it. The Mac answers its own "which
        // of these three?" with an ordinal, and the phone reads a
        // number as "press that badge" — and `/api/voice` runs the
        // command server-side and only then returns, so the phone's
        // handler fired after the Mac had already clicked. Two clicks,
        // two different targets, from one word. Suppressing on the
        // response's `executed` flag was worse than nothing: it is true
        // for "needs your approval" (nothing clicked) and false when
        // the Mac tried and failed (badge press then fires over a
        // screen that just changed).
        //
        // Badges up means the phone owns it, so the Mac is told to
        // leave ordinals alone.
        const badgesUp = Array.isArray(this.numbers) && this.numbers.length > 0;
        fetch(`${this.baseUrl}/api/voice${badgesUp ? '?badges=1' : ''}`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${this.token}`,
            },
            body: formData,
        })
            .then(r => r.json())
            .then(result => {
                if (!this.sameEra(era)) return;
                // "approve" / "deny" answer whatever is waiting, before the
                // Mac gets a chance to read them as a command. The Mac has no
                // notion of the pending queue — the phone is the only side
                // that knows which card is on top — so this is resolved here.
                // A form on screen with a field armed means speech is a
                // value, not a command. Checked before everything else.
                // A number while the badges are up means that badge, and
                // nothing else — "3" must not become a search for "3".
                //
                // …unless the Mac already acted on it. `/api/voice` runs
                // the command server-side and THEN returns, so by the
                // time this line reads the transcript the click may
                // already have happened. When the Mac answers its own
                // "there are 3 things called Follow — which one?" with
                // the second Follow, tapping badge 2 as well is a
                // second click on an unrelated control: the badges are
                // numbered over everything on screen, not over the
                // three candidates.
                if (badgesUp && this.pressNumber(result && result.transcript)) return;
                if (this.fillFieldByVoice(result && result.transcript)) return;
                if (this.answerByVoice(result && result.transcript)) return;
                this.displayVoiceResult(result);
                // A spoken command can raise an approval; pick it up at once.
                this.loadApprovals();
            })
            .catch(err => {
                console.error('Failed to upload audio:', err);
                if (this.handsFree) return;   // see displayVoiceResult
                this.displayVoiceResult({ error: 'Failed to process voice command' });
            });
    },

    // Fill the field you tapped, by voice.
    //
    // Tap a field to arm it, then say "type andres" or "choose pro". The
    // field comes from the tap, so the utterance only has to carry the
    // value — which is the whole reason this is safe to do by speech. The
    // verb is stripped (a "span-select": the value is the span AFTER the
    // verb, not the whole transcript), so "type andres" never types the word
    // "type", which is exactly the bug the old whole-transcript path had.
    //
    // Runs before the approval shortcut and before the Mac sees it as a
    // command: while a form is open and a field is armed, speech is data.
    VERBS: {
        type: ['type', 'typed', 'enter', 'write', 'put', 'fill', 'set', 'input'],
        choose: ['choose', 'select', 'pick', 'set to'],
        clear: ['clear', 'empty', 'erase', 'delete that'],
    },

    fillFieldByVoice(transcript) {
        if (!transcript) return false;
        const sheet = document.getElementById('formSheet');
        if (!sheet || sheet.classList.contains('hidden')) return false;
        const key = this.focusedField;
        if (!key || !this.specFields || !this.specFields[key]) return false;

        // A password never goes through the microphone. The whole reason the
        // Send text sheet exists is that speech means transcription, a model,
        // and a log line, and this sheet's own copy promises it does not
        // happen — so the code has to actually refuse, not just be careful.
        // Say it and nothing is filled; type it instead.
        if (this.specFields[key].secret) {
            this.toast('Type a password — never say it out loud', true);
            return true;   // handled: the Mac must not hear it either
        }

        const said = transcript.trim().replace(/[.!?]+$/, '');

        const after = (verbs) => {
            for (const verb of verbs) {
                // Whole word, at the start. "type andres" yes; "prototype x" no.
                //
                // Matched case-insensitively against the ORIGINAL rather
                // than measured against a lowercased copy: lowercasing
                // does not preserve length for every code point ("İ"
                // becomes two UTF-16 units), so slicing by the lowered
                // length could cut a character early and prepend a
                // fragment of the verb to the value.
                const m = said.match(new RegExp(`^${verb}\\b\\s*([\\s\\S]*)$`, 'i'));
                if (m) return m[1].trim();
            }
            return null;
        };

        if (after(this.VERBS.clear) === '') {
            this.setFieldValue(key, '');
            this.toast(`Cleared ${this.specFields[key].label}`);
            return true;
        }

        const chooseValue = after(this.VERBS.choose);
        if (chooseValue) return this.chooseByVoice(key, chooseValue);

        const typeValue = after(this.VERBS.type);
        if (typeValue) {
            this.setFieldValue(key, typeValue);
            this.toast(`${this.specFields[key].label}: ${typeValue}`);
            return true;
        }
        return false;
    },

    // Match what was heard against the options that actually exist, rather
    // than putting a spoken string into a select that has no such value.
    chooseByVoice(key, spoken) {
        const field = this.specFields[key];
        const wanted = spoken.toLowerCase();

        if (field.toggle) {
            const on = ['on', 'yes', 'true', 'enabled', 'checked'].includes(wanted);
            const off = ['off', 'no', 'false', 'disabled', 'unchecked'].includes(wanted);
            if (!on && !off) return false;
            this.setFieldValue(key, on);
            this.toast(`${field.label}: ${on ? 'on' : 'off'}`);
            return true;
        }

        const options = (field.choices || []).map(o => (typeof o === 'string' ? o : o.value));
        const exact = options.find(o => String(o).toLowerCase() === wanted);
        const partial = options.find(o => String(o).toLowerCase().includes(wanted));
        const hit = exact || partial;
        if (!hit) {
            this.toast(`No “${spoken}” in ${field.label}`, true);
            return true;   // handled: do not let the Mac run it as a command
        }
        this.setFieldValue(key, hit);
        this.toast(`${field.label}: ${hit}`);
        return true;
    },

    setFieldValue(key, value) {
        const field = this.specFields[key];
        if (!field) return;
        this.specState[key] = value;
        if (field.toggle) field.input.checked = !!value;
        else field.input.value = String(value);
    },

    // Answer the card on top by voice. Returns true when it handled the
    // utterance, so the caller does not also treat it as a Mac command.
    answerByVoice(transcript) {
        if (!transcript) return false;
        const said = transcript.toLowerCase().replace(/[^a-z\s']/g, ' ').trim();
        if (!said) return false;

        // Only short, unambiguous utterances. "deny that request" counts;
        // "open the deny folder" does not, and neither does a sentence that
        // happens to contain the word.
        const words = said.split(/\s+/).filter(Boolean);
        if (words.length > 3) return false;

        const YES = ['approve', 'approved', 'allow', 'accept', 'yes', 'confirm', 'ok', 'okay'];
        const NO = ['deny', 'denied', 'reject', 'refuse', 'block', 'cancel', 'stop'];
        const NEG = ["don't", 'dont', 'not', 'never', 'no'];

        const hasYes = words.some(w => YES.includes(w));
        const hasNo = words.some(w => NO.includes(w));
        const negated = words.some(w => NEG.includes(w));

        // "don't approve" used to approve: the affirmative was tested first
        // and the negation in front of it was never looked at. Saying the
        // opposite of what you meant is the worst failure this can have, so
        // anything that is not one clean intent is handed to the Mac as an
        // ordinary command instead of being acted on here.
        let wants = null;
        if (negated) {
            // "don't approve" is a refusal. "don't deny" is not a clear
            // approval, so it is not treated as one. A bare "no" is a refusal.
            if (hasYes && !hasNo) wants = 'deny';
            else if (!hasYes && !hasNo) wants = 'deny';   // "no", "never"
            else wants = null;                            // "don't cancel" etc.
        } else if (hasYes && hasNo) {
            wants = null;                                 // "approve cancel"
        } else if (hasYes) {
            wants = 'allow';
        } else if (hasNo) {
            wants = 'deny';
        }
        if (!wants) return false;

        // The one on screen. Only one card is ever shown, so "approve" can
        // only mean the card you are looking at — there is nothing for it to
        // pick between.
        const approval = this.visibleApproval();
        if (!approval) return false;
        if (approval.handoffOnly) {
            this.toast('That one has to be pressed at the Mac', true);
            return true;
        }

        const { allow, deny } = this.resolveIntents(approval);
        const option = wants === 'allow' ? allow : deny;
        if (!option) {
            this.toast(`Cannot tell which button means “${wants}” here — tap one`, true);
            return true;
        }

        // A spoken word is the easiest input to get wrong, so a high-risk
        // option asks on screen rather than acting on what it thought it heard.
        if ((option.riskLevel || 'low') === 'high') {
            this.showConfirmation(approval, option, approval.id, option.id);
            return true;
        }

        this.submitDecision(approval.id, option.id);
        return true;
    },

    displayVoiceResult(result) {
        const resultEl = document.getElementById('voiceResult');
        const transcriptionEl = document.getElementById('voiceTranscription');
        const decisionEl = document.getElementById('voiceDecision');

        const failed = !!result.error || !result.transcript;

        // Hands free records continuously and cuts on silence, so a good
        // share of segments are a cough, a door, or half a word — and every
        // one of them used to put "Unable to transcribe" on the screen. That
        // is noise about nothing the person did. When the microphone is just
        // sitting open, a failed segment says nothing at all; it stays in the
        // console for debugging. Push-to-talk is the opposite: you
        // deliberately held a button, so silence back would look broken.
        if (failed && this.handsFree) {
            // Hands-free records continuously, so most segments are room noise
            // and genuinely have nothing in them. Saying so quietly beats
            // saying nothing: a screen that never changes looks broken, and
            // there was no way to tell a missed word from a dead microphone.
            console.warn('[allowly] hands-free segment not transcribed', result.error || '');
            this.noteHeard(null);
            return;
        }

        if (result.error) {
            transcriptionEl.textContent = `Could not make that out`;
            decisionEl.textContent = '';
        } else {
            // The server field is `transcript`; reading `transcription` made a
            // perfectly good result render as "Unable to transcribe".
            transcriptionEl.textContent = result.transcript
                ? `“${result.transcript}”`
                : 'Could not make that out';
            decisionEl.textContent = result.decision || '';
        }

        resultEl.classList.remove('hidden');
        this.noteHeard(result.transcript || null, result.decision);

        // Auto-hide after 5 seconds if no approval was made
        setTimeout(() => {
            if (!result.requestId) {
                resultEl.classList.add('hidden');
            }
        }, 5000);
    },

    // ── Seeing that you were heard ──────────────────────────────────────
    //
    // The transcript used to appear for five seconds and then vanish, and in
    // hands-free mode a segment that failed showed nothing at all. So the
    // common experience was speaking at a screen that never changed, with no
    // way to tell whether the words had arrived, arrived wrong, or not been
    // picked up at all. These two keep that visible.

    showVoiceLevel(level, speaking) {
        const row = document.getElementById('voiceLive');
        const bar = document.getElementById('voiceLevelBar');
        const text = document.getElementById('voiceLiveText');
        if (!row || !bar) return;
        row.classList.remove('hidden');
        // 6 is the speech threshold used above; 45 is a loud voice close up.
        bar.style.width = `${Math.min(100, Math.round((level / 45) * 100))}%`;
        if (text) text.textContent = speaking ? 'Hearing you…' : 'Listening…';
    },

    hideVoiceLevel() {
        document.getElementById('voiceLive')?.classList.add('hidden');
    },

    /// null means a segment arrived with nothing intelligible in it.
    noteHeard(transcript, decision) {
        const list = document.getElementById('voiceHistory');
        if (!list) return;
        const when = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        const row = document.createElement('li');
        if (!transcript) {
            row.className = 'missed';
            const b = document.createElement('b');
            b.textContent = 'didn\u2019t catch that';
            row.appendChild(b);
        } else {
            const b = document.createElement('b');
            // textContent, always: a transcript is untrusted text and this is
            // the one place it is put on screen.
            b.textContent = `\u201C${transcript}\u201D`;
            row.appendChild(b);
            if (decision) {
                const d = document.createElement('i');
                d.style.fontStyle = 'normal';
                d.textContent = `\u2192 ${decision}`;
                row.appendChild(d);
            }
        }
        const stamp = document.createElement('span');
        stamp.textContent = when;
        row.appendChild(stamp);
        list.prepend(row);
        while (list.children.length > 4) list.removeChild(list.lastChild);
    },

    // Settings
    openSettings() {
        this.openSheet('settingsSheet');
    },

    closeSettings() {
        this.closeSheet('settingsSheet');
    },

    closeAllModals() {
        document.querySelectorAll('.modal').forEach(modal => {
            modal.classList.add('hidden');
        });
        this.confirmData = null;
        this.pendingRemember = null;
    },

    /// Give the endpoint back, so the old Mac's pushes stop arriving.
    ///
    /// Nothing tells the Mac: it finds out on its next send, when the
    /// push service answers 410 Gone and `PushStore` drops the row.
    /// That is the protocol working as designed, and it means unpairing
    /// does not depend on the Mac being reachable.
    async unsubscribeFromPush() {
        try {
            if (!navigator.serviceWorker) return;
            const registration = await navigator.serviceWorker.ready;
            const existing = await registration.pushManager.getSubscription();
            if (existing) await existing.unsubscribe();
        } catch (e) {
            console.warn('Could not cancel the push subscription:', e);
        }
    },

    async subscribeToPush(registration) {
        // `pushManager.subscribe` is a network round trip to Apple and
        // can take seconds; unpairing inside it used to POST to the old
        // Mac and paint "Notifications unavailable" for a machine you
        // deliberately left.
        const era = this.era();
        try {
            const response = await fetch(`${this.baseUrl}/api/vapid-key`, {
                headers: { 'Authorization': `Bearer ${this.token}` },
            });
            const { vapidKey, error } = await response.json();
            if (!vapidKey) throw new Error(error || 'the Mac returned no key');

            // VAPID keys are base64url. atob() only reads standard base64 and
            // throws on - and _, so the alphabet and padding are restored first.
            const padded = vapidKey.replace(/-/g, '+').replace(/_/g, '/')
                .padEnd(vapidKey.length + (4 - vapidKey.length % 4) % 4, '=');
            const raw = atob(padded);
            const applicationServerKey = Uint8Array.from(raw, c => c.charCodeAt(0));

            // An existing subscription made with a different key must go first;
            // subscribe() rejects outright when the keys disagree.
            const existing = await registration.pushManager.getSubscription();
            if (existing) {
                const previous = new Uint8Array(existing.options.applicationServerKey || []);
                const same = previous.length === applicationServerKey.length &&
                    previous.every((byte, i) => byte === applicationServerKey[i]);
                if (!same) await existing.unsubscribe();
            }

            const subscription = await registration.pushManager.subscribe({
                userVisibleOnly: true,
                applicationServerKey,
            });
            if (!this.sameEra(era)) { await subscription.unsubscribe().catch(() => {}); return; }

            const saved = await fetch(`${this.baseUrl}/api/subscribe`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${this.token}`,
                },
                body: JSON.stringify(subscription),
            });
            if (!saved.ok) throw new Error(`the Mac rejected the subscription (${saved.status})`);
            // …and the Mac says no with a 200. `/api/subscribe` answers
            // `{"ok":false,"error":…}` for a subscription it could not
            // decode, and `{"ok":false}` in the startup window before
            // the handler is registered — both with status 200. Reading
            // the status alone brought back the exact lie the settings
            // row was fixed for: "Notifications are on." with nothing
            // stored on the Mac.
            const outcome = await saved.json().catch(() => ({ ok: true }));
            if (outcome && outcome.ok === false) {
                throw new Error(outcome.error || 'your Mac would not store it');
            }

            console.log('[allowly] push subscription registered');
            return subscription;
        } catch (error) {
            console.error('Failed to subscribe to push:', error);
            // Not for a Mac you deliberately left. The era check after
            // `subscribe()` covered the success path only, so unpairing
            // during the /api/vapid-key fetch still painted this.
            if (this.sameEra(era)) {
                this.showPushBanner(`Notifications unavailable — ${error.message}`);
            }
            return null;
        }
    },
};

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    APP.init();
});

// Handle visibility changes to reconnect if needed
document.addEventListener('visibilitychange', () => {
    if (!document.hidden && !APP.state.connected && APP.baseUrl) {
        APP.connectWebSocket();
    }
});
