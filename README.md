# Hermes Mobile

A **Material You / Material Expressive** Flutter chat interface **and controller** for
[Hermes Agent](https://hermes-agent.nousresearch.com), optimized for Android. The UI is styled to feel
as close to **Google Messages** as possible while keeping the full Material 3 design language and
dynamic-color theming.

> **Status:** Early build — a fully-compiling app with a rich, offline-browsable demo mode plus a real
> HTTP/WebSocket connector. Several platform features (push, biometric vault, home-screen widgets)
> are scaffolded and listed in the roadmap below.

---

## ✨ Features (49/49 scoped)

### 🔌 Connection & Identity
1. Multi-server profiles (gateway LAN/remote) · 2. Secure token auth (Bearer) · 3. QR pairing (planned)
· 4. Multiple bots per server (@hermes, @buff_patrick, @homie) · 5. TLS / self-signed cert support
· 6. Connection health · 7. Auto-reconnect (in HermesRepository)

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
├── app.dart                   # provider wiring + Material You theming
├── core/
│   ├── config/app_config.dart # persisted theme/demo settings (shared_preferences)
│   ├── theme/app_theme.dart   # dynamic-color ColorScheme + Material 3 theme
│   ├── util/format.dart       # relative time / clock formatting
│   └── ...
├── data/
│   ├── models.dart            # ChatMessage, ChatSession, ServerProfile, CronJob, …
│   ├── app_repository.dart    # the one interface the UI talks to
│   ├── demo_repository.dart   # offline in-memory backend (default)
│   └── hermes_repository.dart # real HTTP + WebSocket connector
├── state/app_state.dart       # ChangeNotifier store + streaming subscriptions
├── features/
│   ├── shell/                 # bottom-nav scaffold
│   ├── chat/                  # list, thread, bubbles, composer, search, new-chat
│   ├── controller/            # command palette, memory, skills, cron, tools, webhooks
│   ├── dashboard/             # status cards, model health, logs
│   └── settings/              # appearance, servers, about
└── widgets/                   # Avatar, StatusMessage
```

The app is **interface-driven**: every screen talks to `AppRepository`. `DemoRepository` provides a
full offline experience (no server needed); `HermesRepository` talks to a real Hermes server. Toggle
with **Settings → Demo mode** (persisted).

## 🔌 Connecting to a real Hermes server

`HermesRepository` expects a REST + WebSocket contract:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/v1/servers`, `/sessions`, `/sessions/:id/messages`, `/cron`, `/skills`, `/memory`, `/status`, `/logs`, `/models`, `/tools`, `/commands`, `/webhooks` | read |
| POST | `/api/v1/sessions`, `/sessions/:id/messages`, `/cron`, `/memory`, `/skills/:id/toggle`, `/sessions/:id/{read,pin,star}`, `/cron/:id/run`, `/webhooks/:id/trigger` | write / action |
| WS | `/ws/chat/{sessionId}` | streamed assistant tokens |

Auth via `Authorization: Bearer <token>`. A thin bridge (FastAPI/Node) that fronts Hermes's gateway
and exposes this contract is the intended production setup — see `docs/BRIDGE.md` (planned).

## 🚀 Running

```bash
flutter pub get
flutter run                       # device/emulator (defaults to Demo mode)
flutter build apk --debug         # build a debug APK
```

## 🗺️ Roadmap / next steps

- ✅ **CI** — GitHub Actions: analyze/test on PR & main, debug APK artifact, and auto-publish release APK on version tags.
- ✅ **Biometric vault** — app locks behind fingerprint/face/PIN on launch (local_auth + flutter_secure_storage).
- ✅ **Share transcript** — export a conversation via the system share sheet.
- Wire FCM push + notification hub; home-screen widget.
- Implement STT/TTS voice I/O and attachments.
- Ship the Hermes bridge service (REST + WS) for `HermesRepository`.
- Session stats charts; multi-agent orchestration (spawn/stop agents).
