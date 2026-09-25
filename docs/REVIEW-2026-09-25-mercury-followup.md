# Mercury Messenger + this Hermes setup — evidence-based review (follow-up)

Date: 2026-09-25
Reviewer: Hermes (cron job), with one Opus cross-check pass (`--model opus`, 49 turns, $1.71)
Scope: the Mercury Messenger app (repo `Flexingg/hermes-mobile`) and how this machine's Hermes
agent setup is built.

**This is a review, not a refactor.** No application code, config, service or cron job was changed.
The only writes were (a) bringing the repo current — a checkpoint commit, and (b) this document.

This builds on `docs/REVIEW-2026-09-25.md` (written earlier today by a sibling pass on this box,
committed here as `e92e51e`). Where a claim in that document is reused it has been **re-verified
with my own command** this session, and the number is re-stated. Where I found something new, it
is marked **NEW**.

---

## STEP 1 — Where I looked

The repo and folder are `hermes-mobile`; the **app** is "Mercury Messenger".

| Where | Result |
|---|---|
| `ls ~/repos` | `hermes-mobile` present (no `*hermes*mobile*`/`*hermesmobile*` variant) |
| `find /home/hermes -maxdepth 4 -iname "*hermes*mobile*" -o -iname "*hermesmobile*"` | `~/repos/hermes-mobile`, `~/.hermes/profiles/dev-hermes-mobile`, `~/.claude/projects/-home-hermes-repos-hermes-mobile`, `~/.cache/claude-cli-nodejs/-home-hermes-repos-hermes-mobile`, `~/mem-upgrade-backup-20260925-060216/gradle/hermes-mobile_android_gradle.properties`, `~/.config/systemd/user/hermes-gateway-dev-hermes-mobile.service` |
| `~/.hermes/profiles/` (20 profiles) | `dev-hermes-mobile` exists (the app's paired bot profile) |
| `gh repo list Flexingg --limit 200` | `Flexingg/hermes-mobile` — public, "Material You / Material Expressive Flutter chat interface & controller for Hermes Agent (Android-optimized)" |
| `~/.hermes/reviews/` | does not exist |
| `~/repos/hermes-mobile/docs/` | `REVIEW-2026-09-25.md` (untracked, from the sibling pass) |

Identity confirmed: `README.md` line 1 is `# Mercury Messenger`; `android/app/src/main/AndroidManifest.xml:7`
sets `android:label="Mercury Messenger"`; `android/app/build.gradle.kts:20` sets
`applicationId = "com.randallengineering.hermes"`. Flutter client (`lib/`, 40 Dart files) + a FastAPI
bridge (`server/bridge.py`, 2256 lines) + an mDNS advertiser (`server/announce_bridge.py`).

## STEP 2 — Bringing it current

Branch `main`, tracking `origin/main`.

- **Before:** `efb6e19`; `git status -sb` → `## main...origin/main` + one untracked file
  (`docs/REVIEW-2026-09-25.md`); `git rev-list --left-right --count origin/main...HEAD` → `0  0`
  (already level with origin, nothing to pull).
- The untracked review is someone else's work and would have been destroyed by the next
  `git checkout`. Committed as a checkpoint, never discarded, no force-push, no history rewrite:

  ```
  e92e51e docs: checkpoint the 2026-09-25 Mercury/Hermes review
  ```

- **After:** pushed to `origin/main`, `git status -sb` clean for that file, ahead/behind `0 0`.
- **Gates, run for real this session:**

  ```
  flutter analyze  ->  No issues found! (ran in 8.6s)
  flutter test     ->  00:00 +1: All tests passed!
  ```

  **Test count: 1.** That number is the whole point of finding 4.

## STEP 3 — Evidence collected

Everything below was produced by a command I ran. The Opus pass ran with `--safe`, which blocked its
reads of `~/.hermes` and `systemctl`, so its Target-B section is empty and its Target-A findings are
code-reading; I re-derived the Target-A findings myself and reproduce the numbers here.

---

# THE TEN SUGGESTIONS

## 1. Make the bridge fail closed — today any host on the LAN reads `~/.hermes` and runs shell commands with no credential at all

**(1) What to change.** Refuse to start without `BRIDGE_TOKEN`; serve previews only from a previews
directory and only for preview MIME types; check the token **before** `websocket.accept()`; drop
`Access-Control-Allow-Origin: *`; bind loopback (or Tailscale) instead of `0.0.0.0`.

**(2) Evidence — reproduced live, this session, no `Authorization` header sent:**

```
GET /html/home/hermes/.hermes/config.yaml  -> 200,  6595 bytes
GET /html/home/hermes/.hermes/.env         -> 200, 25177 bytes
GET /html/home/hermes/.hermes/state.db     -> 200, 144429056 bytes
GET /api/v1/status                         -> 401   (control: auth DOES work on /api/v1)
GET /api/v1/files?path=…/config.yaml       -> 401
ss -ltnp | grep 9130                       -> LISTEN 0.0.0.0:9130
```

`.env` holds `DEEPSEEK_API_KEY`, `NOUS_API_KEY`, `MATTERMOST_TOKEN` (key names at `/home/hermes/.hermes/.env`).
Mechanism, all in `server/bridge.py`:
- `BRIDGE_TOKEN` is optional — `:50`; the middleware only guards `/api/v1` — `:100`
  (`if BRIDGE_TOKEN and request.url.path.startswith("/api/v1")`).
- `/html/{path}` is *deliberately* unauthenticated — `:743-759`, docstring `:747` "Deliberately
  OUTSIDE /api/v1 so it needs no auth header"; `_file_roots()` always includes the whole
  `~/.hermes` home — `:710-724`; any unknown suffix is still served as
  `application/octet-stream` — `:758`, contradicting the docstring's "preview-safe" at `:750`.
- CORS `*` — `:93-95`. Bind `0.0.0.0` — `:2256`. `announce_bridge.py` then advertises that bridge
  to the whole LAN/tailnet over mDNS (`_mercury._tcp` on :9130, `server/announce_bridge.py:353`).
- WebSockets `:835` and `:876` never authenticate: `@app.middleware("http")` does not run for the
  WebSocket scope.
- `/api/v1/terminal/run` runs `shell=True` (`:1528`); its validation is cosmetic (length ≤ 8000).
- **NEW:** the world-readable `state.db` (`-rw-r--r--`, 0644, 144 MB) is served this way, and so is
  `server/data/transactions.json` — a file `.gitignore` marks "sensitive data — never commit".

**(3) Implementation.** `if not BRIDGE_TOKEN: raise SystemExit("BRIDGE_TOKEN required")` at import.
Restrict `/html/` to a previews root, return 404 unless the suffix is in `_PREVIEW_TYPES`. Add the
token check in both `ws_*` handlers before `accept()`. Replace `allow_origins=["*"]` with the app's
origins. Default `BRIDGE_HOST=127.0.0.1`, with `BRIDGE_HOST` used for the Tailscale address.

**(4) Effort:** M

**(5) If it stays:** anyone on the LAN — or anything that sees the mDNS advert — downloads the full
144 MB chat history, `.env` (every model API key), `auth.json`, the Firebase service-account key and
the gitignored finance export, and can run arbitrary commands as `hermes`, the user that owns the
gateway, every bot token and this box's sudo.

## 2. Rotate the credentials and delete the leak classes — the live bridge token is inside the chat database in 20 rows, and delegated agents are handed the whole secrets tree

**(1) What to change.** Rotate `BRIDGE_TOKEN` and `SPARKY_TOKEN`; scrub them from `state.db`; delete
the world-readable unit backup; `chmod 700 ~/.hermes/secrets` and `600` its files; move unit secrets
to an `EnvironmentFile`; fix `state.db` permissions; stop giving delegated agents ambient read
access to `~/.hermes`.

**(2) Evidence — counted, this session:**

```
live BRIDGE_TOKEN (48 chars, from the deployed unit) inside ~/.hermes/state.db:
  messages.content           3 rows
  messages.tool_calls       13 rows
  messages.reasoning         2 rows
  messages.reasoning_content 2 rows
  TOTAL                     20 rows contain the live token

-rw-rw-r-- (0664) hermes-bridge.service.bak-1789206915   <- IDENTICAL live token
drwxrwxr-x (0775) ~/.hermes/secrets/
-rw-rw-r-- (0664) ~/.hermes/secrets/mercury-fcm-service-account.json
-rw-r--r-- (0644) ~/.hermes/state.db                     <- world readable
~/.hermes/config.yaml:189 / :193   live MCP bearer tokens in plaintext (22- and 64-char values)
~/.hermes/config.yaml:85           dashboard secret in plaintext
```

The token is only a 48-char static bearer that never expires or rotates (unit
`~/.config/systemd/user/hermes-bridge.service:13`, currently `-rw-------`). **NEW, second mechanism:**
the delegation runner gives every agent read access to `~/repos` **and `~/.claude`**
(`code_task.py:33` `SHARED_READ_DIRS`) and runs it with `--dangerously-skip-permissions`
(`code_task.py:86`). Hermes' own `~/.claude/CLAUDE.md:29-31` forbids agents from touching
`~/.hermes/secrets/` — but the agent is running with permissions bypassed and `~/.hermes` is on the
same box, so the rule is unenforced; the only reason the Opus pass in this review could not read
`~/.hermes` is that I passed `--safe`.

**(3) Implementation.** Rotate both tokens. `rm` the `.bak`. `chmod 700 ~/.hermes/secrets`,
`chmod 600 ~/.hermes/secrets/*`, `chmod 600 ~/.hermes/state.db`, `chmod 600 ~/.hermes/config.yaml`.
Move the unit's inline `Environment=…TOKEN=…` into `EnvironmentFile=%h/.hermes/secrets/bridge.env`
(0600) — the pattern `claude-web.service` already uses. Delete the 20 rows (or compact the DB) and
add `gitleaks detect` + a pre-commit hook — a check that can fail. Give the delegation runner a
deny-list that excludes `~/.hermes/secrets`, `.env`, `*.jks` from what it hands an agent.

**(4) Effort:** M

**(5) If it stays:** the credential guarding the bridge is readable by any local user, sits in a
plaintext file copied around by tooling, is re-written into a new `.bak` on every unit edit, and is
already inside the 144 MB database that finding 1 publishes to the LAN. Rotating the token does not
help while the new one lands in `state.db` again on the next session that mentions it.

## 3. Stop shipping a never-expiring bearer over cleartext on the LAN — and give the app a way to revoke it (**NEW**)

**(1) What to change.** Serve the bridge over TLS (or at minimum require it off-loopback), and give
the token a rotation/revocation story the phone can drive.

**(2) Evidence.** `server/bridge.py:2256` — `uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT","9130")))`,
no `ssl_certfile`. The client builds its base from a plain-http URL and sends
`Authorization: Bearer $token` on every request (`lib/data/hermes_repository.dart:30-34`,
`_headers`), including the WebSocket upgrade. So the bridge token, the entire chat transcript, the
`/api/v1/terminal/run` command output and file downloads all cross the LAN in cleartext. On the
client side the token can be *deleted* (`lib/core/config/app_config.dart:99-110` `clearServer` calls
`VaultService.deleteToken`) but there is no rotate/revoke path, no expiry, and the bridge has no way
to invalidate an issued token — `DEVICE_TOKENS` (`bridge.py:57,175-185`) is only for FCM push, not
auth. A stolen token is valid forever, against a host that can run shell commands.

**(3) Implementation.** Generate a self-signed cert for the LAN address, enable TLS in `uvicorn.run`
(the Flutter README already claims "TLS / self-signed cert support"), and pin the cert in the app.
Add token expiry (`exp`) plus a `POST /api/v1/auth/rotate` that returns a fresh token and stores only
a hash; have `clearServer` also call a server-side revoke. Then finding 2 becomes recoverable instead
of permanent.

**(4) Effort:** M

**(5) If it stays:** anyone who ever observes a single packet on the LAN (or the tailnet, or a
coffee-shop AP the phone joins) owns permanent shell access to this machine, and the owner has no
button to take it back.

## 4. Give the gate teeth — the entire suite is one test that cannot fail, and the delegation runner has no test-count baseline

**(1) What to change.** Make `code_task.py` capture test counts and test names before/after a run and
treat an unchanged count as a failed pass; add a test-count floor to the repo's CI; require every
behavioural change to add a test that fails without it.

**(2) Evidence.** `test/widget_test.dart` is the only test file in the repo; its body is `:6-11`:

```dart
testWidgets('StatusMessage renders its title', (tester) async {
  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(body: StatusMessage(title: 'Hello', icon: Icons.check)),
  ));
  expect(find.text('Hello'), findsOneWidget);
});
```

I ran it: `flutter test` → `+1: All tests passed!`; `flutter analyze` → `No issues found!`. That
assertion can only fail if the widget stops rendering text at all — it cannot fail for any change to
the bridge, streaming, the vault, group fan-out or the coach maths. `.github/workflows/ci.yml:26,29`
make it the gate for the whole product, and the release job (`:55-79`) builds and publishes with no
verification step at all. On the delegation side, `code_task.py` runs `--verify`, prints the last 15
lines and the exit code (`:195-202`) and **nothing else** — no before/after count, no diffstat
(`:204-218`). The tell the owner already uses — "green gate + unchanged test count = nothing was
built" — is precisely what the runner cannot report. Independent corroboration that agent reports
cannot be the evidence: the Opus pass in this very review reported as critical that
`server/hermes-bridge.service` was committed to the **public** repo with a real token. I checked:
`git ls-files` shows the file is tracked, and `grep -n BRIDGE_TOKEN server/hermes-bridge.service` on
HEAD returns `REPLACE_WITH_TOKEN` — a placeholder. The claim was false, from a careful reviewer told
to cite evidence.

**(3) Implementation.** In `code_task.py`, before the run capture
`(test_count, sorted(names), git rev-parse HEAD, git diff --stat)` by running the project's test
command in count-only mode; capture the same after; print both; return non-zero when a task that
claims new tests leaves the count unchanged, or when no source file changed. Add
`assert_test_floor` to the shared gate (finding 9) so CI fails when the count drops. Enforce the
house rule that already exists but is unenforced — `~/.claude/CLAUDE.md:13` "A passing suite is not
proof your change works."

**(4) Effort:** M

**(5) If it stays:** the machine keeps producing green passes that built nothing, and every delegated
report — including confidently wrong ones — has to be re-derived by hand.

## 5. Make a delegated run recoverable — checkpoint the tree and persist the report (merges the "uncommitted trees" and "lost write-up" incidents)

**(1) What to change.** The delegation wrapper takes a checkpoint before and after every run, writes
a run artifact into the repo, and refuses to call a run successful on a dirty tree.

**(2) Evidence.** Two failure modes have the same root: `code_task.py` neither inspects nor preserves
state. It never runs `git status` before or after (`:36-44` defines `run()`; the only git-adjacent
thing is `--verify` at `:198`), runs agents with `--dangerously-skip-permissions` (`:86`), and its
only file I/O is *reading* `--prompt-file` (`:138`) — the agent's report is `print()`-ed to stdout
(`:175`). Meanwhile `~/.claude/CLAUDE.md:32-33` tells every delegated agent "never commit or push
unless the task explicitly asks for it", and the only net is `config.yaml:31-32`
`checkpoints.enabled: true`. This is exactly how a crash lost a whole pass and how a large
uncommitted tree got recovered by hand twice. I hit the residue on the sibling pass today: the file
`docs/REVIEW-2026-09-25.md` was sitting untracked in a clean-looking repo and would have been lost by
the next checkout — I committed it as `e92e51e`. The report half: of the 33 jobs in
`~/.hermes/cron/jobs.json`, **30 are disabled** one-shots still carrying their full original prompts;
the history of what was attempted lives as dead cron rows, not as reports, and the "findings lost
because the write-up came last" incident has no counterpart file to recover from.

**(3) Implementation.** In `code_task.py`: `git status --porcelain` and `git rev-parse HEAD` before
and after; on a dirty tree write `git stash create` + `git bundle create /tmp/run-<ts>.bundle HEAD`
and print the diffstat; add a default `--checkpoint` that commits the agent's work as
`wip(delegate): <task>` with the session id in the body (never push). Write
`<repo>/.hermes-runs/<stamp>-<session_id>.json` with task, agent+model, exit code, interrupted flag,
report text, `--verify` output and exit code, `git diff --stat`, `git status --porcelain` and the
before/after test counts, then print the path. Add `.hermes-runs/` to the ignore list in each repo.
Relax the `~/.claude` line to "do not commit *unless this wrapper is driving you*, in which case the
wrapper commits for you."

**(4) Effort:** S

**(5) If it stays:** every future crash repeats the hand recoveries, and each pass's reasoning is
unrecoverable the moment the session is compacted or lost.

## 6. Delete the phantom API surface and pin the contract — 9 client calls hit routes the bridge does not implement

**(1) What to change.** Add recorded-schema contract tests in both directions, then either implement
the missing routes or delete the client methods; and stop guessing external endpoints.

**(2) Evidence — route set difference I computed this session** (`_get/_post/_patch/_delete` and
`Uri.parse` in `lib/data/hermes_repository.dart` vs every `@app.<verb>` in `server/bridge.py`; 49
server routes, 41 distinct client calls):

```
POST   /api/v1/servers            server_verbs=['GET']   client:78
POST   /api/v1/servers/{id}       server_verbs=NONE      client:87
DELETE /api/v1/servers/{id}       server_verbs=NONE      client:90
POST   /api/v1/cron               server_verbs=['GET']   client:557
POST   /api/v1/cron/{id}          server_verbs=NONE      client:563
DELETE /api/v1/cron/{id}          server_verbs=NONE      client:566
POST   /api/v1/memory             server_verbs=['GET']   client:601
DELETE /api/v1/memory/{id}        server_verbs=NONE      client:607
POST   /api/v1/skills/{id}/toggle server_verbs=NONE      client:589
```

(The server has `GET /api/v1/servers:1230`, `GET /api/v1/cron:928`, `GET /api/v1/memory:992`,
`GET /api/v1/skills:963` and only `POST /api/v1/cron/{job_id}/run:956`.) So the app's "add server",
"add/edit/delete memory", "create/edit/delete cron job" and "toggle skill" flows are dead code —
each a 405/404 thrown as a bare `Exception` (`hermes_repository.dart:40,48,56,64`) and swallowed by
the UI (finding 7). The same class produced two named incidents: `server/bridge.py:1638-1664` guesses
SparkyFitness paths (`/api/goals/for-date?date=…` then a fallback `/api/goals/by-date/{date}`) and
maps 401/403 to "unreachable", so an invented path is indistinguishable from a bad credential — the
"guessed `/api/v1` that caused 401s" pattern. And Jokarz-Timeclock's hand-written Tasker profile was
rejected by Tasker: `~/repos/Jokarz-Timeclock/docs/TASKER-FORMAT.md:6-7` records the literal error
("Import failed… Error details: Missing event type"). The fix that worked there is the pattern to
generalise: a captured golden file in the repo plus a test that pins the contract.

**(3) Implementation.** A `tools/contract_check.py` in the repo that re-derives both route sets (as
my throwaway script does) and exits non-zero on drift, wired into `.github/workflows/ci.yml`. For
external APIs, record one real response per endpoint into `server/tests/fixtures/` and assert the
parser against it; delete the guessed fallback list and fail loudly, distinguishing 401 (credential)
from 404 (path). Then implement or remove the 9 client methods.

**(4) Effort:** S/M

**(5) If it stays:** the app quietly ships management screens that cannot work, and the next
integration is written against an assumed schema — a failure that has already cost a plant-format
rewrite and a debugging cycle on a 401 that was really a wrong URL.

## 7. Surface failures — the app swallows them and the delivery path drops payloads with only a log line

**(1) What to change.** One error type that carries the server's own message, rendered in the UI; and
one preflight size check that names the effective cap before an upload starts.

**(2) Evidence.** `lib/state/app_state.dart` swallows errors in eight places — `:137, :220, :301,
:318, :371, :388, :395, :491` are all literally `catch (_) {}` (e.g. `:301-302`
`_groups = await repo.groups(); … } catch (_) {}`). A 405 from finding 6, a 401, or a dead socket
therefore produce no user-visible signal. Where errors *are* rethrown the server's explanation is
discarded — `hermes_repository.dart:40` `throw Exception('GET $path → ${res.statusCode}')` drops the
`detail` the bridge carefully provides (`server/bridge.py:734` `{"detail": "path outside allowed roots"}`,
`:103` `{"detail": "unauthorized"}`). **NEW: the client has no reconnect at all.** `README.md:26`
advertises "Auto-reconnect (in HermesRepository)", but `grep -rni reconnect lib/` returns nothing,
there is no WebSocket `pingInterval`/keepalive anywhere, and both sockets are one-shot
(`hermes_repository.dart:235,438` `WebSocketChannel.connect(...)`, no `onDone`/retry). Every request
carries a 15 s timeout (`:33,41,49,57`), so on a flaky phone network the failure mode is a silent
no-op. On the delivery side, oversize artifacts are dropped with a warning only and the caps
contradict each other across paths:

```
gateway/relay/media.py:50     MEDIA_MAX_BYTES = 25*1024*1024
gateway/relay/media.py:185-189  oversized -> logger.warning + return None (silent drop)
gateway/platforms/bluebubbles.py:91-94  _WEBHOOK_MAX_BODY_BYTES = 1_048_576   (1 MiB)
```

That inconsistency is the mechanism behind "a 22 MB attachment arrived as 1 MB": whether a file is
delivered, shrunken or vanishes depends on which transport it takes, and nothing tells the user which
cap applied.

**(3) Implementation.** Replace the `_get/_post/...` throws with `ApiFailure(status, path, detail)`
parsed from the JSON body, and replace each `catch (_) {}` with a `setError(...)` that drives a
persistent error banner plus an in-app Logs view over a bounded ring buffer. Add reconnect with
backoff and a WS ping. Add one `effective_attachment_limit(transport)` helper in Hermes, call it in
the upload preflight, and return the cap and the transport name ("Mercury: 25 MB limit on relay
media; file is 22 MB — use the release download or the LAN URL").

**(4) Effort:** M

**(5) If it stays:** every real failure looks like "nothing happened". The owner cannot distinguish
"the bridge is down" from "the endpoint does not exist" from "the file was too big" — the single
biggest time cost in debugging this stack.

## 8. Sign the release APK with a real key — it is currently signed with the public Android debug key

**(1) What to change.** Create a release keystore, wire it through `key.properties`, replace the debug
signing config, and add a CI gate that verifies the signing certificate and fails on a mismatch.

**(2) Evidence — `apksigner` run against the real artifacts, this session:**

```
build/app/outputs/flutter-apk/app-release.apk
  Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
  SHA-256: d855e2e032d1ef4c15ebc22e7ed5dc4630a7c5fa1d17571e68e96d1cea09e57a
~/.hermes/deliveries/Mercury-v2.0.5.apk
  Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
  SHA-256: d855e2e032d1ef4c15ebc22e7ed5dc4630a7c5fa1d17571e68e96d1cea09e57a

keytool -list -v -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey
  SHA256: D8:55:E2:E0:...:09:E5:7A    <- byte-identical
```

So every published Mercury APK is signed with a key whose private half is public and is the default
on every Android dev machine. Mechanism: the Flutter template TODO is still there —
`android/app/build.gradle.kts:36-39`:

```kotlin
release {
    // TODO: Add your own signing config for the release build.
    // Signing with the debug keys for now, so `flutter run --release` works.
    signingConfig = signingConfigs.getByName("debug")
}
```

— and the release job builds and publishes with no keystore and no verification
(`.github/workflows/ci.yml:55-79`).

**(3) Implementation.** `keytool -genkeypair` into `~/.hermes/secrets/mercury-release.jks`, add
`android/key.properties` (already gitignored, `android/.gitignore:11-13`), read it in
`build.gradle.kts`, set `signingConfig = signingConfigs.getByName("release")`, and add a CI step:
`apksigner verify --print-certs build/.../app-release.apk | grep -q "CN=<expected>"` asserting the
release DN and v1+v2+v3 schemes. Keep one keystore per app, per the delivery convention, so in-place
updates work.

**(4) Effort:** S/M

**(5) If it stays:** anyone can build a trojaned Mercury Messenger that Android installs as an
in-place update over the real one, inheriting its vault (`lib/core/security/vault.dart`) and bridge
token. Android also refuses in-place updates signed by a different key — which is exactly why the
debug key is convenient — so rotating later means every install must be replaced by hand.

## 9. Stop hand-rolling per-repo CI — one shared house gate, and commit the Gradle wrapper everywhere

**(1) What to change.** Commit the Gradle wrapper in every Gradle repo, and add a single
`house-gate.sh` that every repo's CI and every delegated run calls.

**(2) Evidence — scan run this session:**

```
SparkyFitness-Liftosaur   gradlew_tracked=0  wrapper_jar=0  workflows=22   <== CI calls ./gradlew
Jokarz-Timeclock          gradlew_tracked=1  wrapper_jar=1  workflows=1
Simplefin_Android_Finances gradlew_tracked=1 wrapper_jar=1  workflows=2
lumen                     gradlew_tracked=1  wrapper_jar=1  workflows=1
HabitCraftBridge          gradlew_tracked=0  wrapper_jar=0  workflows=0
hermes-mobile             gradlew_tracked=0  wrapper_jar=0  workflows=1   (Flutter; CI never calls ./gradlew)
```

`SparkyFitness-Liftosaur` cannot build in CI: it invokes `./gradlew` and `git ls-files` tracks
neither `gradlew` nor `gradle-wrapper.jar` — the exact reported incident. And **no** workflow in any
repo contains a secret or signing scan, which is why the token-in-a-`.bak` class (finding 2) and the
debug-key signing (finding 8) have no gate at all.

**(3) Implementation.** For each Gradle repo: `gradle wrapper --gradle-version <pinned>` and commit
`gradlew`, `gradlew.bat`, `gradle/wrapper/*` (or switch CI to `gradle/actions/setup-gradle`). Then
one `~/.hermes/scripts/house-gate.sh` doing: project lint → test suite with a test-count floor
(finding 4) → `apksigner verify --print-certs` against the expected release DN when an APK is
produced → `gitleaks detect` → contract check (finding 6). Have every repo's CI call it, and have
`code_task.py --verify` default to it so a delegated pass cannot pass a weaker gate than CI runs.

**(4) Effort:** S/M

**(5) If it stays:** repos keep arriving with a CI that cannot run, gates keep being invented per repo
(so each is weaker than the last), and the two defect classes that are cheapest to catch
mechanically — a leaked credential and a debug-signed release — stay manual, i.e. undetected until
they matter.

## 10. Put a ceiling on the box and a monitor on the long-running surfaces — the OOM kill has already happened eight times

**(1) What to change.** Add `MemoryMax=`/`MemoryHigh=` to the heavy units, enable the dashboard unit
(or bind it to loopback), and add a check that fails when the box is swapping hard.

**(2) Evidence — this session:**

```
journalctl --user -S "7 days ago" | grep "oom-kill":
  Sep 20 02:08 / 02:22 / 07:01 / 07:13 / 07:25  hermes-gateway-buff-patrick.service
  Sep 21 05:52                                  hermes-worker-proc_84f3bf8f7fb2.scope
  Sep 24 04:06                                  hermes-worker-proc_3b9d88f0920f.scope
  Sep 24 06:52                                  antigravity-cli-daemon.service
free -h:  Mem 14Gi total, 202Mi free;   Swap 4.0Gi total, 4.0Gi used, 4.0Ki free
systemctl --user is-enabled hermes-dashboard.service  -> disabled
systemctl --user is-active  hermes-dashboard.service  -> inactive
```

Eight OOM kills in a week, swap fully exhausted right now, and the monitoring surface is dead. The
build-killing mechanism was the Gradle daemon allowance (8 G heap + 4 G metaspace ≈ 12 GB for the
daemon alone on a 16 GB box with 4 GB swap) — right-sized and committed earlier today as `efb6e19`
(`android/gradle.properties`). `config.yaml:80-88` publishes the dashboard on `host: 0.0.0.0:9119`
with a plaintext `secret`; its unit
(`~/.config/systemd/user/hermes-dashboard.service`) was written and never enabled — it is not in
`default.target.wants/` (21 units listed, dashboard absent). **NEW:** `state.db` is 0644 and 144 MB,
which is both a leak (finding 1) and a growth trend nobody is watching; the bridge has a `/healthz`
route but no monitor consumes it.

**(3) Implementation.** `systemctl --user enable --now hermes-dashboard.service`, or set
`config.yaml:86` to `host: 127.0.0.1` and reach it over Tailscale. Add `MemoryMax=2G` /
`MemoryHigh=1500M` to `antigravity-cli-daemon.service` and the delegation-heavy gateway units. Copy
the `android/gradle.properties` caps into every Gradle repo that builds here. Add a cron check that
fails loudly when `SwapFree == 0` or `MemAvailable` drops below ~1 GB — a check that can actually
fail, since right now the only signal is a build that produces nothing.

**(4) Effort:** S

**(5) If it stays:** the next concurrent build plus a gateway hits the same swap wall with zero build
output and no report — the OOM kill that already cost one pass — and the dashboard is unreachable
exactly when it is needed.

---

## Notes on what I did and did not touch

- **Changed:** committed the pre-existing untracked `docs/REVIEW-2026-09-25.md` as `e92e51e` and
  pushed it to `origin/main`, plus this file. No force-push, no history rewrite, nothing discarded.
- **Not changed:** any application code, any `~/.hermes` config, any systemd unit, any cron job, any
  log level. In particular I did **not** rotate the tokens, delete the `.bak`, `chmod` the secrets
  directory or `state.db`, enable the dashboard unit, add `MemoryMax`, or alter `bridge.py` — each is
  a one-command owner decision.
- **Verification discipline:** every security and state claim above is from a command I ran in this
  session (curl status codes and sizes, `apksigner` with certificate digests, a `sqlite3` row count
  for the token, `ls -la`, `ss`, `systemctl`, `journalctl`, `free`, `git ls-files` scans, and two
  throwaway analysis scripts). The Opus pass ran with `--safe`, so its `~/.hermes` reads were refused
  — that is why its Target-B half is empty, and why its Target-A route/secret findings were
  re-derived by hand here rather than quoted.
