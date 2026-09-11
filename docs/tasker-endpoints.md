# Tasker-triggerable endpoints (Hermes Mobile bridge)

The bridge (`server/bridge.py`, FastAPI on `:9130`) is the Hermes-facing HTTP surface. This adds a
small **Tasker-triggerable** API so the phone can kick off a Hermes run by HTTP — no app needed.

All endpoints below live under **`/api/v1`**, so the existing auth middleware applies: every call
must send `Authorization: Bearer <BRIDGE_TOKEN>`. Do **not** add these outside `/api/v1`.

## Use case: "open Obsidian, then tell Hermes to scan my files"

The owner opens their Obsidian/markdown vault, then triggers (from Tasker, or a launcher action)
a Hermes run that scans/reads the vault and reports back (an index/summary of new or changed notes).

### `POST /api/v1/tasker/run`

Generic, extensible trigger. Body (JSON, all optional unless noted):

```json
{
  "task": "scan_vault",          // required; name of a registered task
  "path": "/home/hermes/vault",  // optional; defaults to MER_VAULT_PATH env
  "mode": "scan",                // task-specific hint: scan | index | summarize
  "note": "opened in Obsidian",  // optional free-text context appended to the prompt
  "wait": false                  // false → 202 + sessionId; true → block (bounded) and return the answer
}
```

Response (default, async):

```json
{ "ok": true, "task": "scan_vault", "sessionId": "20260910_..._ab12cd", "path": "/home/hermes/vault" }
```

Implementation notes:

- A small **task registry** maps a task name → prompt builder, so more triggers can be added later
  without new routes. Start with `scan_vault` (and optionally `daily_digest`).
- `scan_vault` builds a prompt like: *"Scan my Obsidian vault at `<path>`. Summarize what's new or
  changed, list any TODO/checklist items, and write/update an index note. Be concise."* — pass the
  text as the `-q` argument to `hermes chat` (reuse the existing `_spawn_*` pattern:
  `subprocess.Popen([HERMES_BIN, "chat", "-q", prompt, "--pass-session-id"], start_new_session=True, stdin=DEVNULL)`
  in a background thread). **No `shell=True`** and never string-interpolate user input into a shell
  command — pass it as an argv element.
- **Async by default**: return `202` with the session id immediately; run the Hermes subprocess in a
  background thread and parse its stdout for `Session: <id>` (like `chat_start`).
- If `wait=true`, run synchronously with a bounded timeout (e.g. 180s) and return
  `{ "ok": true, "answer": "<text>", "sessionId": "..." }`.
- **Path safety**: resolve `path` and require it to be inside an allowed vault root. The root is
  `MER_VAULT_PATH` (new env var). **If `MER_VAULT_PATH` is unset/empty, respond `400`
  `"vault not configured — set MER_VAULT_PATH on the bridge"`** (don't scan arbitrary paths). When
  set, `path` from the request may further narrow to a subpath within that root; anything outside →
  `403`.
- **Environment**: `MER_VAULT_PATH` — allowed vault root, no default (must be configured).
  ⚠️ Note for the owner: there is currently **no Obsidian vault on the server** (`hermes-pc`), so the
  vault must be synced there first (Obsidian Sync / git / Syncthing) and `MER_VAULT_PATH` pointed at
  it before a scan can find files. The endpoint should say so clearly rather than silently no-op.
- **Finish notification (nice-to-have)**: reuse the existing FCM device-token mechanism
  (`mercury_devices.json`) to push "Vault scan complete" to the phone when the run finishes, so the
  user gets a ping after opening Obsidian.
- **Logging**: log task name + path + session id (never the token).

### `GET /api/v1/tasker/tasks`

Returns the registered task names + a one-line description, so Tasker/launcher can discover them:

```json
{ "tasks": [ { "name": "scan_vault", "description": "Scan the markdown vault and summarize changes" } ] }
```

## Wiring it in Tasker (document in the report)

Tasker → **Net → HTTP Request**:

- Method: `POST`
- URL: `http://100.67.34.4:9130/api/v1/tasker/run`  *(Tailscale; or the LAN IP `http://192.168.1.146:9130`)*
- Headers: `Authorization: Bearer %BRIDGE_TOKEN`  and  `Content-Type: application/json`
- Body: `{"task":"scan_vault"}`

Recommend the owner store the token in a Tasker variable (and the matching Lumen settings field) and
keep both in sync.

## Environment

- `MER_VAULT_PATH` — allowed vault root for `scan_vault` (default `/home/hermes/vault`).
  The owner must have the Obsidian vault present on the server at this path (synced via Obsidian
  Sync / git / Syncthing etc.) for the scan to find files.

## Acceptance

- `POST /api/v1/tasker/run {"task":"scan_vault"}` with a valid token returns `202` + a session id and
  actually starts a Hermes run that reads the vault; with a bad/absent token → `401`; a path outside
  the vault root → `403`; `GET /api/v1/tasker/tasks` lists `scan_vault`.
- Existing endpoints/behaviour unchanged; bridge still starts cleanly.
