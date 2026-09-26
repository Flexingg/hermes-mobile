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
│   ├── project_models.dart    # Project, ProjectTask, IssueDraft, …
│   ├── app_repository.dart    # the one interface the UI talks to
│   └── hermes_repository.dart # real HTTP + WebSocket connector (only backend)
├── state/app_state.dart       # ChangeNotifier store + connection + streaming
├── features/
│   ├── shell/                 # bottom-nav scaffold
│   ├── projects/              # projects list, link sheet, project tabs, issue card, work
│   ├── chat/                  # list, thread, bubbles, composer, search, new-chat
│   ├── controller/            # command palette, memory, skills, cron, tools, webhooks
│   ├── dashboard/             # status cards, model health, logs
│   └── settings/              # appearance, servers, about
└── widgets/                   # Avatar, StatusMessage
```

The app is **interface-driven** and **real-data only**: every screen talks to `AppRepository`, whose
sole implementation is `HermesRepository`. On first launch the app shows the connect screen and will
not display any data until it has verified a live connection to a Hermes bridge server.

## 📁 Projects (Hermes orchestrates)

Link a GitHub repo in the **Projects** tab and it becomes a project with its own Hermes agent
(`dev-<repo>` profile), memory and kanban board. In a project chat, switch to **Plan**: you and the
agent shape one issue (read-only), and it ends in an editable **Issue card**. **Create issue** files it;
Hermes queues it, a kanban worker has the project's coder (**Claude Code** or **Antigravity**; Hermes
codes itself only as a fallback) implement it in its own worktree, runs the repo's gates, and opens a PR
that closes the issue. When CI is green you get a push, *"… ready for testing"*, with the PR and, for
Android repos, an **Install test build** button. An issue labelled `mercury` on GitHub is picked up too.

The logic lives in Hermes, not in the app or the bridge: skills and scripts in [`hermes/`](hermes/)
(installed into `~/.hermes` by `hermes/install.sh`), Hermes' kanban, and three `--no-agent` cron jobs.
The bridge only reads Hermes' state and relays; a test fails if it ever files an issue, creates a task,
opens a PR or kills a process. Design and decisions: [`docs/PLAN-projects-orchestrator.md`](docs/PLAN-projects-orchestrator.md).

**Tap a task** and you get its own page: issue, PR, CI, coder, branch, when it merged, the test build —
and the three things you can do with it.

| Action | What happens |
|---|---|
| **Ask <project>** | Opens the project agent's chat with the issue/PR already in the composer, so you type one sentence |
| **Suggest edits** | One note, sent to Hermes as an `edit_task` intent. An open PR → the note goes back on the task and its worker updates the same branch; a merged one → Hermes hands it to the project agent as new work |
| **File a follow-up issue** | The project agent scopes your note against the code, checks for duplicates, and files it queued like any other issue |

**A merged PR closes its own task.** `mercury-ci` notices the merge, marks the task `merged`, sends one
*"#42 merged"* push, and removes the worktree and both copies of the branch. A PR closed *without*
merging ends the task too, but deletes nothing (nothing landed) and says so.

```bash
hermes/install.sh           # scripts, skills, push guard, notify key, cron jobs (idempotent)
hermes/install.sh --check   # what's installed
```

## 🔌 The Hermes bridge

`HermesRepository` talks to `server/bridge.py`, a FastAPI service that fronts a **real** Hermes
install and returns live data:

| Data | Source (real) |
|------|---------------|
| Sessions & messages | `~/.hermes/state.db` (SQLite) |
| Chat (streaming) | the resident gateway's **API server** (`127.0.0.1:8642`, SSE; other profiles under `/p/<profile>/` when the gateway multiplexes them); `hermes chat --resume <session>` subprocess for image turns or when the API server can't take the turn. Streamed to the app over WebSocket either way |
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
Chat goes through the Hermes gateway's API server when it is enabled (`API_SERVER_KEY` in
`~/.hermes/.env`). The bridge reads that one key from the file, so it isn't copied anywhere.
With `gateway.multiplex_profiles: true` the same gateway serves every profile under `/p/<profile>/`,
each authenticated by its own `API_SERVER_KEY` in `~/.hermes/profiles/<profile>/.env`.

Hermes keeps **one `state.db` per profile**. The bridge lists the default profile's chats plus those of
`MER_CHAT_PROFILE` (the profile new chats from the app run as), and every read, send, pin or delete
goes to the profile whose database holds that chat.
Override with `HERMES_API_URL` / `HERMES_API_KEY`. `GET /api/v1/status` reports `hermesApi: true`
while the API server is in use. A turn it can't take falls back to the CLI; a turn that fails
half-way is reported, not re-run (that would answer twice).
Or install the included systemd user unit (`server/hermes-bridge.service`) to run it persistently.

**App contract** (`HermesRepository`): every `GET`/`POST`/`PATCH`/`DELETE` under `/api/v1/*` sends an
`Authorization` header carrying the bridge token; chat streams over `WS /ws/chat/{sessionId}` (the upgrade carries the same
bearer — an HTTP middleware never runs for the WebSocket scope), and in-app HTML previews are fetched
from `GET /html/<abs path>?token=…` because a WebView cannot attach a header.

Every failure surfaces the bridge's own `{"detail": …}` message in the app's error strip
(`ApiFailure`), so a 401 (bad token), a 404 (route does not exist) and a dead socket are
distinguishable instead of all looking like "nothing happened".

## 🌍 Reaching the bridge from outside your network

Three ways, picked on the connect screen (**How do you reach it?**), because they are for different
days: none of them is a fallback for another.

| | Address | Needs | Notes |
|---|---|---|---|
| **Local network** | `http://192.168.x.x:9130` | same Wi-Fi | Fastest; the app can find the bridge by mDNS ("Search your network") |
| **Tailscale** | `http://100.x.y.z:9130` | the VPN on the phone | Nothing is exposed publicly; the bridge still speaks plain HTTP inside the tailnet |
| **Cloudflare tunnel** | `https://….trycloudflare.com` (or your own hostname) | nothing, or a domain | Works on any network, TLS terminated at the edge; ask Hermes to start it |

```bash
python3 ~/.hermes/mercury/bin/mercury_tunnel.py up      # start (prints the URL)
python3 ~/.hermes/mercury/bin/mercury_tunnel.py status  # is it up, and where
python3 ~/.hermes/mercury/bin/mercury_tunnel.py down    # stop exactly what it started
```

Or just tell Hermes *"start the tunnel"* — it runs the same script and quotes the URL back — and then
tap **Use the tunnel my server has open** on the connect screen, which reads `GET /api/v1/tunnel` and
fills the address in. The bridge never starts or stops the tunnel itself; it only reports what that
script left behind (test-enforced).

- `cloudflared` dials **out** to Cloudflare and forwards to `http://127.0.0.1:9130`, so no inbound port
  is opened and the bridge can stay bound to loopback.
- The tunnel runs as a **systemd `--user` unit** (`mercury-tunnel`), so it survives the chat turn or cron
  tick that started it and `down` stops it by name. Without a user manager, a detached process with a
  recorded pid is used instead.
- A **quick tunnel** is free and needs no account, but its URL changes every start and Cloudflare
  authenticates nobody on it — the bridge token is the only gate. For anything lasting, create a named
  tunnel, point it at `127.0.0.1:9130` in `~/.cloudflared/config.yml`, and put a **Cloudflare Access**
  policy in front of it: then `up --hostname bridge.example.com` gives a stable URL, and the app's
  optional *Access client ID / secret* fields send the service token on every request (including the
  WebSocket handshake). Both halves are stored in the Android keystore, like the API token.

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
  Tailscale interface (`BRIDGE_HOST=<tailnet ip>`), or reach it through a Cloudflare tunnel so TLS is
  terminated at the edge (see above); `BRIDGE_HOST=127.0.0.1` closes the port entirely. The bridge
  prints a warning when it binds a non-loopback address.
- **A quick tunnel is public.** The URL is random but unauthenticated at the edge, so `BRIDGE_TOKEN` is
  the only gate on it — use a named tunnel with a Cloudflare Access policy for anything beyond trying it
  out, and `mercury_tunnel.py down` when you are done.
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
`apksigner verify --print-certs`, failing unless the DN is `CN=Mercury Messenger` and the v2+v3
schemes verify. (Every previous release was signed with the public Android debug key, so anyone could
build a trojaned in-place update.) Keep one keystore per app so updates install in place.

## ✅ Tests

```bash
flutter analyze && flutter test          # 59 tests: repository, ApiFailure, reconnect, AppState, banner, projects, task actions, CLI noise
cd server && python -m pytest tests -q   # 121 tests: bridge auth, routes, API-server chat, per-profile chats, project views, chat plumbing
cd hermes && python -m pytest tests -q   # 60 tests: the Hermes-side scripts, run as Hermes runs them
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
