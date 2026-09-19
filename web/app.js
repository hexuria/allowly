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
    tapToClick: false,
    screenNudge: null,
    screenTick: null,
    hints: [],
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
        this.restoreSession();
        this.setupEventListeners();
        this.detectPlatform();

        if (this.baseUrl && this.token) {
            this.showMainScreen();
            this.startScreenPolling();
            this.connectWebSocket();
            if (localStorage.getItem('jev-hands-free') === 'true') {
                this.syncHandsFreeToggles(true);
                this.setHandsFreeStatus('Tap anywhere to start listening', '');
                // iOS will not open a microphone without a user gesture, so it
                // cannot simply resume — one tap arms it again.
                const arm = () => {
                    document.removeEventListener('touchend', arm);
                    document.removeEventListener('click', arm);
                    this.startHandsFree();
                };
                document.addEventListener('touchend', arm, { once: true });
                document.addEventListener('click', arm, { once: true });
            }
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

        if (localStorage.getItem('jev-push-dismissed') === 'true') return;

        if (isIOS && !this.isInstalled()) {
            show('Add Jev to your Home Screen so approvals can reach you when the app is closed.');
            return;
        }
        if (!supported) return;
        if (Notification.permission === 'granted') {
            this.ensurePushSubscription();
            return;
        }
        if (Notification.permission === 'denied') {
            show('Notifications are blocked. Approvals will only appear while Jev is open.');
            return;
        }
        show('Get told when something needs your approval.', 'Turn on');
        action.onclick = async () => {
            // Must run inside the gesture — iOS ignores a deferred request.
            const permission = await Notification.requestPermission();
            if (permission !== 'granted') {
                show('Notifications are blocked. Approvals will only appear while Jev is open.');
                return;
            }
            banner.classList.add('hidden');
            this.ensurePushSubscription();
        };
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
    async ensurePushSubscription() {
        if (!('serviceWorker' in navigator) || !('PushManager' in window)) return;
        if (Notification.permission !== 'granted') return;
        if (!this.token || !this.baseUrl) return;
        try {
            const registration = await navigator.serviceWorker.ready;
            await this.subscribeToPush(registration);
        } catch (error) {
            console.error('Push subscription failed:', error);
        }
    },

    isInstalled() {
        return window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
    },

    // Restore session from localStorage, or pair straight from the URL.
    restoreSession() {
        try {
            const stored = localStorage.getItem('jev-session');
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
    },

    // Save session to localStorage
    saveSession() {
        localStorage.setItem('jev-session', JSON.stringify({
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
            localStorage.setItem('jev-push-dismissed', 'true');
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
        ['handsFree', 'handsFreeMain'].forEach(id => {
            document.getElementById(id)?.addEventListener('change', (e) => {
                if (e.target.checked) this.startHandsFree(); else this.stopHandsFree();
            });
        });
        document.getElementById('tapToClick')?.addEventListener('change', (e) => {
            this.tapToClick = e.target.checked;
            document.getElementById('screenImage')?.classList.toggle('tappable', this.tapToClick);
            // Re-arm the timer at the new cadence.
            if (this.screenTimer) { this.stopScreenPolling(); this.startScreenPolling(); }
        });

        document.getElementById('typeSend')?.addEventListener('click', () => this.sendTypedText());
        document.getElementById('formSubmit')?.addEventListener('click', () => this.submitForm());
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
                this.startScreenPolling();
                if (localStorage.getItem('jev-hands-free') === 'true' && !this.handsFree) {
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
            alert('Please enter a pairing URL');
            return;
        }

        try {
            const parsed = new URL(url);
            const token = parsed.searchParams.get('token');

            if (!token) {
                alert('Invalid pairing URL: missing token parameter');
                return;
            }

            this.baseUrl = url.split('?')[0];
            this.token = token;
            this.saveSession();
            this.showMainScreen();
            this.connectWebSocket();
        } catch (e) {
            alert('Invalid pairing URL format');
        }
    },

    changePairing() {
        this.baseUrl = null;
        this.token = null;
        localStorage.removeItem('jev-session');
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
        document.getElementById('currentUrl').value = this.baseUrl || '';
    },

    // WebSocket connection
    connectWebSocket() {
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

            this.ws.addEventListener('close', () => {
                this.setConnectionStatus(false);
                this.ws = null;
                // Attempt to reconnect after 2 seconds
                setTimeout(() => this.connectWebSocket(), 2000);
            });

            this.ws.addEventListener('error', (error) => {
                console.error('WebSocket error:', error);
                this.setConnectionStatus(false);
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
        const statusEl = document.getElementById('connectionStatus');
        const statusText = document.getElementById('statusText');

        if (connected) {
            statusEl.classList.remove('disconnected');
            statusEl.classList.add('connected');
            statusText.textContent = 'Connected';
        } else {
            statusEl.classList.remove('connected');
            statusEl.classList.add('disconnected');
            statusText.textContent = 'Disconnected';
        }
    },

    handleWebSocketMessage(data) {
        try {
            const message = JSON.parse(data);

            if (message.type === 'hints') {
                this.renderHints(message.hints || [], message.mode || 'numbers');
            } else if (message.type === 'hintBox') {
                this.outlineHint(message.number);
            } else if (message.type === 'approval') {
                this.handleNewApproval(message.approval);
            } else if (message.type === 'resolved') {
                this.handleResolvedApproval(message.id);
            } else if (message.type === 'needInput') {
                this.promptForInput(message.field, message.secret);
            } else if (message.type === 'form') {
                this.showForm(message.fields || []);
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
        if (id === 'settingsSheet') this.loadPolicy();
    },

    closeSheet(id) {
        document.getElementById(id)?.classList.add('hidden');
    },

    // Pull frames only while the Screen tab is visible. Capturing and shipping
    // a full-resolution JPEG is not free, so it must stop when nobody is
    // looking — including when the phone is backgrounded.
    pollScreenOnce() {
        if (document.hidden) return;
        this.screenTick();
    },

    startScreenPolling() {
        if (this.screenTimer) return;
        this.installScreenGestures();
        this.installScreenZoom();
        this.installCursorDrag();
        const tick = () => {
            if (document.hidden) return;
            const img = document.getElementById('screenImage');
            const status = document.getElementById('screenStatus');
            const started = Date.now();
            if (!this.baseUrl || !this.token) {
                status.textContent = 'Not paired — open the pairing link again';
                return;
            }
            status.textContent = 'Fetching…';
            // Belt and braces: a changing query defeats any cache that ignores
            // no-store, which is what left the view stuck on an old workspace.
            fetch(`${this.baseUrl}/api/screenshot?token=${encodeURIComponent(this.token)}&t=${started}`,
                  { cache: 'no-store' })
                .then(r => r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`)))
                .then(({ data, cursor }) => {
                    if (!data) throw new Error('empty frame');
                    img.src = `data:image/jpeg;base64,${data}`;
                    this.placeCursor(cursor);
                    status.textContent = `updated ${Date.now() - started} ms ago`;
                })
                .catch(err => { status.textContent = `Screen unavailable: ${err.message}`; });
        };
        this.screenTick = tick;
        tick();
        // Tighter cadence while you are driving the pointer; it matters far
        // more when you are aiming at something than when you are watching.
        this.screenTimer = setInterval(tick, this.tapToClick ? 400 : 1000);
    },

    stopScreenPolling() {
        if (this.screenTimer) {
            clearInterval(this.screenTimer);
            this.screenTimer = null;
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
            : 'Goes to whatever the pointer is on.';

        this.openSheet('inputSheet');
        // iOS needs the focus call in the same turn the sheet becomes visible.
        setTimeout(() => textEl.focus(), 120);
    },

    // The Mac read a form off its own screen. Show it as a real form here so
    // you can see which box each value is going into — typing blind into a
    // remote screen is how the wrong thing ends up in the password field.
    showForm(fields) {
        const list = document.getElementById('formFields');
        const status = document.getElementById('formStatus');
        if (!list) return;

        list.innerHTML = '';
        status.textContent = '';
        this.formFields = fields;

        fields.forEach((field, index) => {
            const wrapper = document.createElement('label');
            wrapper.className = 'form-field';

            const caption = document.createElement('span');
            caption.textContent = field.label;
            wrapper.appendChild(caption);

            const input = document.createElement('input');
            input.className = 'setting-input';
            input.dataset.index = String(index);
            input.type = field.secret ? 'password' : 'text';
            input.autocapitalize = 'off';
            input.autocomplete = field.secret ? 'current-password' : 'off';
            input.spellcheck = false;
            if (/email/i.test(field.label)) input.type = 'email';
            if (/phone/i.test(field.label)) input.type = 'tel';
            wrapper.appendChild(input);

            list.appendChild(wrapper);
        });

        this.openSheet('formSheet');
        setTimeout(() => list.querySelector('input')?.focus(), 120);
    },

    async submitForm() {
        const list = document.getElementById('formFields');
        const status = document.getElementById('formStatus');
        const inputs = Array.from(list.querySelectorAll('input'));
        const filled = inputs.filter(input => input.value !== '');
        if (!filled.length) { status.textContent = 'Nothing to fill'; return; }

        status.textContent = 'Filling…';
        let done = 0;
        for (const input of filled) {
            const field = this.formFields[Number(input.dataset.index)];
            try {
                // Sequentially: each fill focuses a different field, and
                // firing them together races the focus.
                const response = await fetch(`${this.baseUrl}/api/type`, {
                    method: 'POST',
                    cache: 'no-store',
                    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
                    body: JSON.stringify({ text: input.value, field: field.label, secret: !!field.secret }),
                });
                const result = await response.json();
                if (result.ok) done += 1;
                else status.textContent = result.reason || `Could not fill ${field.label}`;
            } catch (error) {
                status.textContent = `Failed on ${field.label}: ${error.message}`;
                break;
            }
            // Never leave a password sitting in the phone's DOM.
            if (field.secret) input.value = '';
        }
        if (done === filled.length) {
            status.textContent = `Filled ${done} field${done === 1 ? '' : 's'}`;
            setTimeout(() => this.closeSheet('formSheet'), 900);
        }
    },

    // Send typed text to the Mac. Passwords belong here rather than in the
    // microphone: nothing is transcribed, and secret text is never logged.
    sendTypedText() {
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
                status.textContent = result.reason || (result.ok ? 'Sent' : 'Failed');
                // Never leave a secret sitting in the box.
                if (secretEl.checked) textEl.value = '';
            })
            .catch(err => { status.textContent = `Failed: ${err.message}`; });
    },

    // Hands free: watch the microphone level, record an utterance when speech
    // starts, stop on silence, upload. Each utterance is a complete recording,
    // which avoids the streaming problem entirely — MediaRecorder chunks after
    // the first cannot be decoded on their own.
    setHandsFreeStatus(text, cls) {
        ['handsFreeStatus', 'handsFreeMainStatus'].forEach(id => {
            const el = document.getElementById(id);
            if (!el) return;
            el.textContent = text;
            el.className = id === 'handsFreeMainStatus' ? `handsfree-status ${cls || ''}` : 'policy-hint';
        });
    },

    syncHandsFreeToggles(on) {
        ['handsFree', 'handsFreeMain'].forEach(id => {
            const el = document.getElementById(id);
            if (el) el.checked = on;
        });
        document.getElementById('pttBtn')?.classList.toggle('hidden', on);
    },

    async startHandsFree() {
        if (this.handsFree) return;
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
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
            localStorage.setItem('jev-hands-free', 'true');
            this.syncHandsFreeToggles(true);
            this.setHandsFreeStatus('Listening…', 'live');

            // Record CONTINUOUSLY and cut on silence, rather than starting the
            // recorder when speech is detected. Starting on detection always
            // clips the first word — "quit Notes" arrived as "Notes", which
            // then reads as a bare app name and opens it.
            const startRecorder = () => {
                chunks = [];
                segmentStarted = Date.now();
                recorder = new MediaRecorder(stream);
                recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
                recorder.onstop = () => {
                    const blob = new Blob(chunks, { type: recorder.mimeType || 'audio/mp4' });
                    const spoke = recorder.jevHadSpeech;
                    if (spoke && blob.size > 6000) this.uploadAudio(blob);
                    if (this.handsFree && !this.handsFree.stop) startRecorder();
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
            localStorage.removeItem('jev-hands-free');
        }
    },

    stopHandsFree() {
        if (!this.handsFree) return;
        this.handsFree.stop = true;
        this.handsFree.stream.getTracks().forEach(t => t.stop());
        this.handsFree.context.close().catch(() => {});
        this.handsFree = null;
        localStorage.removeItem('jev-hands-free');
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
        if (!this.tapToClick) return Promise.resolve();
        if (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) return Promise.resolve();
        return fetch(`${this.baseUrl}/api/tap`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ x: point.x, y: point.y, kind }),
        })
            .then(r => r.json())
            .then(result => {
                const status = document.getElementById('screenStatus');
                if (status && result.reason) status.textContent = result.reason;
                // Pull a frame straight away so you see the effect immediately
                // rather than waiting for the next poll.
                this.refreshScreenSoon();
            })
            .catch(() => {});
    },

    sendSwipe(point, dx, dy) {
        if (!this.tapToClick) return;
        fetch(`${this.baseUrl}/api/swipe`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ x: point.x, y: point.y, dx, dy }),
        }).then(() => this.refreshScreenSoon()).catch(() => {});
    },

    refreshScreenSoon() {
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
    placeCursor(cursor) {
        const marker = document.getElementById('cursorMarker');
        if (!marker) return;
        if (!cursor || typeof cursor.x !== 'number') { marker.classList.add('hidden'); return; }
        // While you are dragging it, your finger is the truth — a frame from
        // before the move would yank it backwards.
        if (marker.dataset.aiming === '1') return;
        marker.style.left = `${cursor.x * 100}%`;
        marker.style.top = `${cursor.y * 100}%`;
        marker.classList.remove('hidden');
    },

    installCursorDrag() {
        const marker = document.getElementById('cursorMarker');
        if (!marker || marker.dataset.wired) return;
        marker.dataset.wired = '1';

        let active = false;

        const positionFrom = (event) => {
            const img = document.getElementById('screenImage');
            const rect = img.getBoundingClientRect();
            const touch = event.changedTouches ? event.changedTouches[0] : event;
            return {
                x: Math.min(1, Math.max(0, (touch.clientX - rect.left) / rect.width)),
                y: Math.min(1, Math.max(0, (touch.clientY - rect.top) / rect.height)),
            };
        };

        const begin = (event) => {
            // Aiming is not clicking, so this works even with tap-to-click off.
            event.preventDefault();
            event.stopPropagation();
            active = true;
            marker.dataset.aiming = '1';
            marker.classList.add('aiming');
        };

        const move = (event) => {
            if (!active) return;
            event.preventDefault();
            event.stopPropagation();
            const point = positionFrom(event);
            marker.style.left = `${point.x * 100}%`;
            marker.style.top = `${point.y * 100}%`;
            // "move" places the pointer without pressing anything.
            this.movePointer(point);
        };

        const end = (event) => {
            if (!active) return;
            event.preventDefault();
            event.stopPropagation();
            active = false;
            marker.classList.remove('aiming');
            this.movePointer(positionFrom(event)).finally(() => {
                // Release only after the Mac has the final position, so the
                // next frame confirms rather than contradicts it.
                marker.dataset.aiming = '0';
            });
        };

        marker.addEventListener('touchstart', begin, { passive: false });
        marker.addEventListener('touchmove', move, { passive: false });
        marker.addEventListener('touchend', end, { passive: false });
        marker.addEventListener('mousedown', begin);
        window.addEventListener('mousemove', move);
        window.addEventListener('mouseup', end);
    },

    // Deliberately not sendPointer: that refuses to act when tap-to-click is
    // off, and moving the pointer is safe whatever that setting says.
    movePointer(point) {
        return fetch(`${this.baseUrl}/api/tap`, {
            method: 'POST',
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${this.token}` },
            body: JSON.stringify({ x: point.x, y: point.y, kind: 'move' }),
        }).catch(() => {});
    },

    installScreenGestures() {
        const img = document.getElementById('screenImage');
        if (!img || img.dataset.gestures) return;
        img.dataset.gestures = '1';

        let startPoint = null;
        let startedAt = 0;
        let longPressTimer = null;
        let mode = null;          // null | 'drag' | 'scroll'
        let lastPoint = null;
        let lastTapAt = 0;

        const begin = (event) => {
            if (!this.tapToClick) return;
            startPoint = this.pointAt(event);
            lastPoint = startPoint;
            startedAt = Date.now();
            mode = null;
            // Holding still for half a second starts a drag from that point.
            longPressTimer = setTimeout(() => {
                mode = 'drag';
                this.sendPointer('dragStart', startPoint);
            }, 500);
        };

        const move = (event) => {
            if (!this.tapToClick || !startPoint) return;
            const point = this.pointAt(event);
            const movedFar = Math.hypot(point.x - startPoint.x, point.y - startPoint.y) > 0.02;

            if (mode === 'drag') {
                this.sendPointer('dragMove', point);
            } else if (movedFar) {
                // Moving before the long press fires means a scroll, not a drag.
                clearTimeout(longPressTimer);
                mode = 'scroll';
                const dx = point.x - lastPoint.x;
                const dy = point.y - lastPoint.y;
                this.sendSwipe(startPoint, dx, dy);
            }
            lastPoint = point;
        };

        const end = (event) => {
            if (!this.tapToClick || !startPoint) return;
            clearTimeout(longPressTimer);
            const point = this.pointAt(event);
            const held = Date.now() - startedAt;

            if (mode === 'drag') {
                this.sendPointer('dragEnd', point);
            } else if (mode === 'scroll') {
                // Already scrolled during the move.
            } else if (held >= 500) {
                this.showTapMarker(point.clientX, point.clientY);
                this.sendPointer('right', point);
            } else {
                this.showTapMarker(point.clientX, point.clientY);
                const now = Date.now();
                const isDouble = now - lastTapAt < 320;
                lastTapAt = isDouble ? 0 : now;
                this.sendPointer(isDouble ? 'double' : 'click', point);
            }
            startPoint = null;
            mode = null;
        };

        img.addEventListener('touchstart', begin, { passive: true });
        img.addEventListener('touchmove', (e) => { e.preventDefault(); move(e); }, { passive: false });
        img.addEventListener('touchend', (e) => { e.preventDefault(); end(e); }, { passive: false });
        img.addEventListener('mousedown', begin);
        img.addEventListener('mousemove', (e) => { if (startPoint) move(e); });
        img.addEventListener('mouseup', end);
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
        if (!id) return;
        this.setPolicy({ id, mode });
        // "never" answers the pending request too: you have said no.
        if (mode === 'never') this.submitDecision(approval.id, 'deny');
        if (mode === 'always') this.submitDecision(approval.id, 'once');
    },

    // Draw the numbered boxes over the screenshot. Coordinates arrive
    // normalised, so they line up whatever the image is scaled to.
    renderHints(hints, mode = 'numbers') {
        const layer = document.getElementById('hintLayer');
        if (!layer) return;
        layer.innerHTML = '';
        this.hints = hints;
        // Numbers alone by default. Eighty outlines over a screenshot obscure
        // the very thing you are trying to look at, and you only need the box
        // when a number is ambiguous.
        layer.className = `hint-layer ${mode === 'boxes' ? 'with-boxes' : 'numbers-only'}`;
        if (!hints.length) return;

        hints.forEach(hint => {
            const box = document.createElement('div');
            box.className = 'hint-box';
            box.dataset.number = hint.number;
            box.style.left = `${hint.x * 100}%`;
            box.style.top = `${hint.y * 100}%`;
            box.style.width = `${hint.width * 100}%`;
            box.style.height = `${hint.height * 100}%`;
            layer.appendChild(box);

            const tag = document.createElement('div');
            tag.className = 'hint-tag';
            tag.dataset.number = hint.number;
            tag.textContent = hint.number;
            // Anchor to the middle of the target rather than its corner:
            // corner labels of adjacent controls collide and overlap.
            tag.style.left = `${(hint.x + hint.width / 2) * 100}%`;
            tag.style.top = `${(hint.y + hint.height / 2) * 100}%`;
            layer.appendChild(tag);
        });

        const status = document.getElementById('screenStatus');
        if (status) status.textContent = `${hints.length} targets — say "select 3" or "show box 3"`;
    },

    // Outline one number without turning the rest into boxes.
    outlineHint(number) {
        const layer = document.getElementById('hintLayer');
        if (!layer) return;
        layer.querySelectorAll('.hint-box.singled').forEach(el => el.classList.remove('singled'));
        const box = layer.querySelector(`.hint-box[data-number="${number}"]`);
        if (box) box.classList.add('singled');
        const tag = layer.querySelector(`.hint-tag[data-number="${number}"]`);
        if (tag) {
            tag.classList.add('singled');
            setTimeout(() => tag.classList.remove('singled'), 2500);
        }
    },

    // Pinch to zoom the screen view. The overlay is positioned in percentages
    // inside the same element, so scaling the container keeps every number
    // registered to the pixel it belongs to.
    installScreenZoom() {
        const stage = document.getElementById('screenStage');
        if (!stage || stage.dataset.zoom) return;
        stage.dataset.zoom = '1';
        let scale = 1, originX = 50, originY = 50, startDistance = 0, startScale = 1;

        const apply = () => {
            stage.style.transformOrigin = `${originX}% ${originY}%`;
            stage.style.transform = `scale(${scale})`;
        };

        stage.addEventListener('touchstart', (e) => {
            if (e.touches.length !== 2) return;
            const [a, b] = e.touches;
            startDistance = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
            startScale = scale;
            const rect = stage.getBoundingClientRect();
            originX = (((a.clientX + b.clientX) / 2) - rect.left) / rect.width * 100;
            originY = (((a.clientY + b.clientY) / 2) - rect.top) / rect.height * 100;
        }, { passive: true });

        stage.addEventListener('touchmove', (e) => {
            if (e.touches.length !== 2 || !startDistance) return;
            e.preventDefault();
            const [a, b] = e.touches;
            const distance = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
            scale = Math.min(5, Math.max(1, startScale * (distance / startDistance)));
            apply();
        }, { passive: false });

        stage.addEventListener('touchend', (e) => {
            if (e.touches.length < 2) startDistance = 0;
            // Snap back when nearly unzoomed, so it cannot be left slightly off.
            if (scale < 1.05) { scale = 1; apply(); }
        });

        // Double tap with two fingers resets.
        stage.addEventListener('dblclick', () => { scale = 1; apply(); });
    },

    // Permissions
    loadPolicy() {
        fetch(`${this.baseUrl}/api/policy?t=${Date.now()}`, {
            cache: 'no-store',
            headers: { 'Authorization': `Bearer ${this.token}` },
        })
            .then(r => r.json())
            .then(policy => this.renderPolicy(policy))
            .catch(err => console.error('Failed to load policy:', err));
    },

    renderPolicy(policy) {
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
            auto: 'Jev judges anything not listed here.',
            ask: 'jev asks about anything not listed here.',
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
            [['always', 'Always'], ['auto', 'Ask Jev'], ['never', 'Never']].forEach(([value, label]) => {
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
        fetch(`${this.baseUrl}/api/pending?t=${Date.now()}`, {
            cache: 'no-store',
            headers: { 'Authorization': `Bearer ${this.token}` },
        })
            .then(r => r.ok ? r.json() : [])
            .then(list => {
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

    handleResolvedApproval(id) {
        this.state.approvals.delete(id);
        this.renderApprovals();
    },

    // Approval rendering
    renderApprovals() {
        const list = document.getElementById('approvalsList');

        if (this.state.approvals.size === 0) {
            list.innerHTML = '<div class="empty-state"><p>No pending approvals</p></div>';
            return;
        }

        list.innerHTML = '';
        this.state.approvals.forEach(approval => {
            const card = this.createApprovalCard(approval);
            list.appendChild(card);
        });
    },

    createApprovalCard(approval) {
        const card = document.createElement('div');
        card.className = 'approval-card';
        if (approval.handoffOnly) {
            card.classList.add('tcc');
        }
        card.id = `approval-${approval.id}`;

        const kindLabel = this.getKindLabel(approval.kind);
        const isTCC = approval.handoffOnly;

        let optionsHTML = '';
        if (isTCC) {
            const vncUrl = this.generateVNCDeepLink(approval);
            optionsHTML = `
                <div class="approval-tcc-notice">
                    <p>This requires direct user interaction. jev cannot auto-answer this. Use Screen Sharing on your Mac to handle it.</p>
                </div>
                <a href="${vncUrl}" class="btn btn-primary" style="text-decoration: none; margin-top: var(--spacing-sm);">Open in Screen Sharing</a>
            `;
        } else {
            optionsHTML = '<div class="approval-options">';
            approval.options.forEach(option => {
                const riskLevel = option.riskLevel || 'low';
                optionsHTML += `
                    <button class="option-btn risk-${riskLevel}" data-request-id="${approval.id}" data-option-id="${option.id}" data-risk="${riskLevel}">
                        <span>${option.label}</span>
                        <span class="risk-indicator">${riskLevel}</span>
                    </button>
                `;
            });
            optionsHTML += '</div>';
        }

        const screenshot = approval.screenshotReference ?
            `<img class="approval-screenshot" src="${approval.screenshotReference}" alt="Screenshot">` : '';

        const timestamp = new Date(approval.timestamp).toLocaleTimeString();

        card.innerHTML = `
            <div class="approval-header">
                <div class="approval-app-info">
                    <div class="approval-app-name">${approval.originatingApp.name}</div>
                    <div class="approval-timestamp">${timestamp}</div>
                </div>
                <span class="approval-kind-badge ${approval.kind.replace(/([A-Z])/g, '-$1').toLowerCase()}">${kindLabel}</span>
            </div>
            <div class="approval-title">${approval.title}</div>
            ${approval.bodyText ? `<div class="approval-body">${approval.bodyText}</div>` : ''}
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
                        this.showConfirmation(approval, option, requestId, optionId);
                    } else {
                        this.submitDecision(requestId, optionId);
                    }
                });
            });
        }

        // Press and hold anywhere on the card for the remembered choices.
        let holdTimer = null;
        const startHold = () => { holdTimer = setTimeout(() => this.openApprovalSheet(approval), 500); };
        const cancelHold = () => clearTimeout(holdTimer);
        card.addEventListener('touchstart', startHold, { passive: true });
        card.addEventListener('touchend', cancelHold);
        card.addEventListener('touchmove', cancelHold, { passive: true });
        card.addEventListener('mousedown', startHold);
        card.addEventListener('mouseup', cancelHold);
        card.addEventListener('mouseleave', cancelHold);

        return card;
    },

    getKindLabel(kind) {
        const labels = {
            agentToolPrompt: 'Agent',
            appDialog: 'Dialog',
            tccConsent: 'System',
            spokenCommand: 'Voice',
        };
        return labels[kind] || kind;
    },

    generateVNCDeepLink(approval) {
        const app = approval.originatingApp.bundleIdentifier || 'unknown';
        return `vnc://${new URL(this.baseUrl).hostname}/?app=${encodeURIComponent(app)}&request=${approval.id}`;
    },

    // Decision submission
    submitDecision(requestId, optionId) {
        const nonce = this.generateNonce();

        const decision = {
            requestId,
            optionId,
            nonce: nonce,
                    };

        this.postDecision(decision);
    },

    showConfirmation(approval, option, requestId, optionId) {
        this.confirmData = { requestId, optionId };

        document.getElementById('confirmTitle').textContent = 'Confirm High-Risk Action';
        document.getElementById('confirmMessage').textContent = `Are you sure you want to ${option.label}? This is a high-risk action.`;

        document.getElementById('confirmModal').classList.remove('hidden');
    },

    submitConfirmedDecision() {
        if (this.confirmData) {
            this.submitDecision(this.confirmData.requestId, this.confirmData.optionId);
            this.confirmData = null;
        }
        this.closeConfirm();
    },

    closeConfirm() {
        document.getElementById('confirmModal').classList.add('hidden');
    },

    postDecision(decision) {
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
                console.log('Decision submitted:', result);
            })
            .catch(err => {
                console.error('Failed to submit decision:', err);
                alert('Failed to submit decision. Please try again.');
            });
    },

    // Nonce generation
    generateNonce() {
        const timestamp = Date.now();
        const random = Math.random().toString(36).substring(2, 8);
        return `${timestamp}-${random}`;
    },

    // Push-to-talk recording
    async startRecording() {
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

            // Use appropriate MIME type for iOS Safari
            // Prefer MP4/AAC. The Mac transcribes with Apple Speech, which
            // cannot open a WebM/Opus container at all — Safari happily records
            // one and every transcription then fails with "Cannot Open".
            let mimeType = '';
            for (const candidate of ['audio/mp4', 'audio/aac', 'audio/mpeg', 'audio/webm']) {
                if (MediaRecorder.isTypeSupported(candidate)) { mimeType = candidate; break; }
            }
            if (!MediaRecorder.isTypeSupported(mimeType)) {
                mimeType = '';
            }

            this.state.mediaRecorder = new MediaRecorder(stream,
                mimeType ? { mimeType } : {}
            );
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
            alert('Microphone permission denied or not available');
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

    uploadAudio(blob) {
        const formData = new FormData();
        const ext = (blob.type || '').includes('webm') ? 'webm'
            : (blob.type || '').includes('mpeg') ? 'mp3' : 'm4a';
        formData.append('audio', blob, `recording.${ext}`);

        document.getElementById('voiceResult').classList.add('hidden');

        fetch(`${this.baseUrl}/api/voice`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${this.token}`,
            },
            body: formData,
        })
            .then(r => r.json())
            .then(result => {
                this.displayVoiceResult(result);
                // A spoken command can raise an approval; pick it up at once.
                this.loadApprovals();
            })
            .catch(err => {
                console.error('Failed to upload audio:', err);
                this.displayVoiceResult({ error: 'Failed to process voice command' });
            });
    },

    displayVoiceResult(result) {
        const resultEl = document.getElementById('voiceResult');
        const transcriptionEl = document.getElementById('voiceTranscription');
        const decisionEl = document.getElementById('voiceDecision');

        if (result.error) {
            transcriptionEl.textContent = `Error: ${result.error}`;
            decisionEl.textContent = '';
        } else {
            // The server field is `transcript`; reading `transcription` made a
            // perfectly good result render as "Unable to transcribe".
            transcriptionEl.textContent = `"${result.transcript || 'Unable to transcribe'}"`;
            decisionEl.textContent = result.decision || 'Processing...';
        }

        resultEl.classList.remove('hidden');

        // Auto-hide after 5 seconds if no approval was made
        setTimeout(() => {
            if (!result.requestId) {
                resultEl.classList.add('hidden');
            }
        }, 5000);
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
    },

    async subscribeToPush(registration) {
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

            const saved = await fetch(`${this.baseUrl}/api/subscribe`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${this.token}`,
                },
                body: JSON.stringify(subscription),
            });
            if (!saved.ok) throw new Error(`the Mac rejected the subscription (${saved.status})`);

            console.log('[jev] push subscription registered');
            return subscription;
        } catch (error) {
            console.error('Failed to subscribe to push:', error);
            this.showPushBanner(`Notifications unavailable — ${error.message}`);
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
