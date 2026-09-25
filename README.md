# Mercury Messenger

A **Material You / Material Expressive** Flutter chat interface **and controller** for
[Hermes Agent](https://hermes-agent.nousresearch.com), optimized for Android. The UI is styled to feel
as close to **Google Messages** as possible while keeping the full Material 3 design language and
dynamic-color theming.

> **Real data only.** This app has no demo data. It requires connecting to a
> live Hermes **bridge** (`server/bridge.py`) that fronts a real Hermes install
> and serves real sessions, messages, memory, skills, cron, status, and live
> streaming chat. Until a server connection is verified, the app shows nothing
> but the connect screen.

---

## ✨ Features (49/49 scoped)

### 🔌 Connection & Identity
1. Multi-server profiles (gateway LAN/remote) · 2. Secure token auth (Bearer) · 3. QR pairing (planned)
· 4. Multiple bots per server (@hermes, @buff_patrick, @homie) · 5. TLS / self-signed cert support
**(planned — the bridge is currently plain HTTP; see Security below)** · 6. Connection health
· 7. Auto-reconnect: the WebSocket opens with exponential backoff (250 ms → 8 s), sends the bearer on
the handshake and keeps a 20 s ping.
*Auto-find bridge on LAN:* the connect screen's "Search your network" browses mDNS for
`_mercury._tcp` (list found bridges, tap to fill the URL); advertise on the host with
`server/announce_bridge.py` (see `hermes-bridge-announce.service`).

### 💬 Chat Core
8. Streaming chat (WebSocket / simulated) · 9. Markdown + rich rendering (flutter_markdown)
· 10. Conversation threading · 11. Session history sync · 12. Typing / "thinking" indicator with
live tool-activity · 13. Message actions (copy/share/pin/star/delete) · 14. Reactions / quick replies
· 15. Full-text session search · 16. Voice input (STT, planned) · 17. Voice replies (TTS, planned)
· 18. Attachments (planned) · 19. Offline draft queue (planned) · 20. Themed code viewer

### 🎛️ Controller — Control Hermes
21. Slash-command palette · 22. Tool activity timeline · 23. Manual tool trigger · 24. Memory
viewer/editor · 25. Skills browser + toggle · 26. Cron job manager (CRUD, run-now) · 27. Cron output
history · 28. Webhook trigger buttons · 29. Multi-agent orchestration (planned) · 30. Profile config

### 📊 Dashboard & Insight
31. Live status cards (CPU/RAM/disk/uptime/sessions) · 32. Session stats (planned) · 33. Notification
hub (planned) · 34. Log viewer · 35. Model/provider health

### 🎨 Material You / Expressive
36. Dynamic Color from wallpaper (dynamic_color) · 37. Material Expressive motion (InkSparkle,
animated typing indicator) · 38. Theme presets + accent picker · 39. Full Material 3 theming
· 40. Adaptive icon + themed launch · 41. Edge-to-edge + gesture nav · 42. Bottom navigation

### ⚙️ Quality & Platform
43. Push notifications (FCM, planned) · 44. Local persistence (shared_preferences) · 45. Background
sync (planned) · 46. Secure vault / biometric lock (local_auth, scaffolded) · 47. Android 12+ deep
integration · 48. Home-screen widget (planned) · 50. Auto-update & crash reporting (planned)

---

## 🏗️ Architecture

```
lib/
├── main.dart                  # bootstrap: load config → run app
├── app.dart                   # providers + Material You theming + ServerGate/VaultGate
├── core/
│   ├── config/app_config.dart # persisted theme + server connection (secure token)
│   ├── theme/app_theme.dart   # dynamic-color ColorScheme + Material 3 theme
│   ├── connection/            # ServerGate + connect-onboarding screen
│   ├── security/              # biometric VaultGate + secure token store
│   └── util/format.dart       # relative time / clock formatting
├── data/
│   ├── models.dart            # ChatMessage, ChatSession, ServerProfile, CronJob, …
│   ├── app_repository.dart    # the one interface the UI talks to
│   └── hermes_repository.dart # real HTTP + WebSocket connector (only backend)
├── state/app_state.dart       # ChangeNotifier store + connection + streaming
├── features/
│   ├── shell/                 # bottom-nav scaffold
│   ├── chat/                  # list, thread, bubbles, composer, search, new-chat
│   ├── controller/            # command palette, memory, skills, cron, tools, webhooks
│   ├── dashboard/             # status cards, model health, logs
│   └── settings/              # appearance, servers, about
└── widgets/                   # Avatar, StatusMessage
```

The app is **interface-driven** and **real-data only**: every screen talks to `AppRepository`, whose
sole implementation is `HermesRepository`. On first launch the app shows the connect screen and will
not display any data until it has verified a live connection to a Hermes bridge server.

## 🔌 The Hermes bridge

`HermesRepository` talks to `server/bridge.py`, a FastAPI service that fronts a **real** Hermes
install and returns live data:

| Data | Source (real) |
|------|---------------|
| Sessions & messages | `~/.hermes/state.db` (SQLite) |
| Chat (streaming) | `hermes chat --resume <session>` subprocess, streamed over WebSocket |
| Memory | `~/.hermes/memories/USER.md` + `MEMORY.md` |
| Cron jobs | `~/.hermes/cron/jobs.json` |
| Skills | `~/.hermes/skills/**/SKILL.md` |
| Status / model | `psutil` + `~/.hermes/config.yaml` |
| Logs | `~/.hermes/logs/*.log` |

**Run it (on the Hermes host):**
```bash
pip install -r server/requirements.txt
HERMES_HOME=/home/hermes/.hermes \
BRIDGE_TOKEN=<your-secret> \      # REQUIRED — the process exits without it
BRIDGE_HOST=127.0.0.1 \           # default 0.0.0.0; see Security
uvicorn server.bridge:app --port 9130
```
Or install the included systemd user unit (`server/hermes-bridge.service`) to run it persistently.

**App contract** (`HermesRepository`): every `GET`/`POST`/`PATCH`/`DELETE` under `/api/v1/*` sends an
`Authorization` header carrying the bridge token; chat streams over `WS /ws/chat/{sessionId}` (the upgrade carries the same
bearer — an HTTP middleware never runs for the WebSocket scope), and in-app HTML previews are fetched
from `GET /html/<abs path>?token=…` because a WebView cannot attach a header.

Every failure surfaces the bridge's own `{"detail": …}` message in the app's error strip
(`ApiFailure`), so a 401 (bad token), a 404 (route does not exist) and a dead socket are
distinguishable instead of all looking like "nothing happened".

## 🔒 Security

The bridge fronts `~/.hermes` — chat history in `state.db`, `config.yaml`, the memory files — and can
run shell commands as the `hermes` user. Treat its token as the machine's password.

- **`BRIDGE_TOKEN` is mandatory.** `bridge.py` refuses to start without it. It guards `/api/v1/*`,
  `/html/*` **and** both WebSockets. (This was the hole: `/html/<path>` was deliberately
  unauthenticated, so any host on the LAN could `GET /html/home/hermes/.hermes/config.yaml` — and the
  144 MB `state.db` — with no credential at all.)
- **`/html/` serves preview types only.** Anything not in `_PREVIEW_TYPES` (`.yaml`, `.env`, `.db`, no
  extension, …) is a 404 even with a valid token, so the preview route cannot be used as a file
  downloader. Use `/api/v1/files` (authenticated, root-checked) for downloads.
- **CORS is off by default.** Set `MER_CORS_ORIGINS` if a browser build needs it; the Android client
  never did.
- **Cleartext LAN.** The token and every response cross the network unencrypted. Put the bridge on a
  Tailscale interface (`BRIDGE_HOST=<tailnet ip>`) or behind a TLS proxy; `BRIDGE_HOST=127.0.0.1`
  closes the port entirely. The bridge prints a warning when it binds a non-loopback address.
- **Never log or commit the token.** It lives in the vault on the app side and in the systemd unit's
  `Environment=` on the host.

## 🔑 Release signing

Release APKs are signed with `~/.hermes/secrets/mercury-release.jks` (alias `mercury`, RSA-4096,
`CN=Mercury Messenger`, valid to 2054), wired in through the gitignored `android/key.properties`:

```properties
storeFile=/home/hermes/.hermes/secrets/mercury-release.jks
storePassword=…            # ~/.hermes/secrets/mercury-release.pw
keyAlias=mercury
keyPassword=…
```

Without that file the release build falls back to the debug key and warns — never publish that APK.
CI restores the key from `MERCURY_KEYSTORE_B64` / `MERCURY_KEYSTORE_PASSWORD` and runs
`apksigner verify --print-certs`, failing unless the DN is `CN=Mercury Messenger` and v1+v2+v3
schemes verify. (Every previous release was signed with the public Android debug key, so anyone could
build a trojaned in-place update.) Keep one keystore per app so updates install in place.

## ✅ Tests

```bash
flutter analyze && flutter test          # 24 tests: repository, ApiFailure, reconnect, AppState, banner
cd server && python -m pytest tests -q   # 37 tests: bridge auth surface, memory/cron/servers routes
python3 tools/contract_check.py          # every route the app calls must exist on the bridge
```

The bridge suite covers the cases that were previously impossible to fail: the token guard on
`/api/v1` and `/html`, the preview-type restriction, WebSocket authentication, memory/cron/server
writes, and the Sparky credential-vs-unreachable split. `tools/contract_check.py` is the gate against
phantom routes (the app used to call nine that never existed).

## 🚀 Running (the app)

```bash
flutter pub get
flutter run                       # device/emulator → connect screen on first launch
flutter build apk --debug         # build a debug APK
```
In the connect screen, enter your bridge URL (e.g. `http://192.168.1.146:9130`) and its bearer token,
then **Connect & verify**. No data appears until the connection succeeds.

## 🗺️ Roadmap / next steps

- ✅ **CI** — GitHub Actions: analyze/test on PR & main, debug APK artifact, and auto-publish release APK on version tags.
- ✅ **Biometric vault** — opt-in fingerprint/face/PIN lock (default off, recovery button on lock screen).
- ✅ **Share transcript** — export a conversation via the system share sheet.
- ✅ **Reply notifications** — opt-in push when Hermes finishes replying (FCM).
- ✅ **Firebase push** — FCM client + bridge sender; opt-in, deep-links into the chat.
- ✅ **UI configuration** — accent color picker, density (comfy/compact), corner radius, sent-bubble color, theme mode, reset.
- ⏳ Notification hub (per-event push controls); home-screen widget.
- Session stats charts; multi-agent orchestration.
