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
· 6. Connection health · 7. Auto-reconnect (in HermesRepository).
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
BRIDGE_TOKEN=<your-secret> \
uvicorn server.bridge:app --host 0.0.0.0 --port 9130
```
Or install the included systemd user unit (`server/hermes-bridge.service`) to run it persistently.

**App contract** (`HermesRepository`): every `GET`/`POST` under `/api/v1/*` sends
`Authorization: Bearer <token>`; chat streams over `WS /ws/chat/{sessionId}`.

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
