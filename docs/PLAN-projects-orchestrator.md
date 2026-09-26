# Plan — Projects, per-repo agents, and the Hermes orchestrator

Status: **v2; Phases 0–6 built (§14–§16); Phase 7 (release) pending** (2026-09-26). Decisions are in §10, Phase 0 findings in §12.

> **v2 change:** v1 made the bridge a second orchestrator (it filed issues, polled GitHub,
> followed CI and governed RAM). That was wrong. **Hermes is the only brain. Mercury is its
> front end.** Every decision and every action runs inside Hermes: its skills, scripts, kanban,
> cron and coder delegation. The bridge is reduced to a thin, authenticated relay between the app and
> Hermes, plus the phone's push outlet.

## 1. What we're building

1. In Mercury you **link GitHub repos** (opt-in). Each becomes a **project** with its own Hermes agent
   (`dev-<repo>` profile) and its own memory.
2. You chat with a project's agent in **Chat** mode, or switch to **Plan** mode, where you and the agent
   shape a GitHub issue together (read-only, no code changes).
3. When the issue exists, **Hermes orchestrates the rest in the background.** It queues the work,
   wakes the project agent, has it delegate the coding to the project's coder (**Claude Code or
   Antigravity**, chosen per project, with Hermes as the fallback), runs the repo's gates, and opens a PR.
4. Hermes tells Mercury when the PR is **ready for testing**: CI green, with the debug APK for Flutter repos.
5. The **orchestrator** (Hermes' default profile, `@hermes`) wakes and sleeps project agents and
   kills runaway ones to keep the machine inside its RAM budget. You can talk to it directly
   in Mercury.

## 2. The one rule: who does what

| Layer | Owns | Must not |
|---|---|---|
| **Mercury app** | Showing state; sending *your* words and taps to Hermes; rendering what Hermes sends back (chat, issue cards, task/PR status, pushes) | decide anything, call GitHub, start processes |
| **Bridge** (`server/bridge.py`) | Auth (`BRIDGE_TOKEN`); relaying chat/intents to Hermes and streaming the replies back; read-only views of Hermes state (kanban, projects, processes); receiving `notify` calls *from Hermes* and turning them into FCM pushes + WS events | file issues, create tasks, poll GitHub, spawn coders, kill processes |
| **Hermes orchestrator** (default profile, resident gateway) | Routing messages to project agents; project linking; issue intake (app + `mercury` label); queueing work on kanban; wake/sleep/kill; follow-up on CI; telling Mercury | write code itself |
| **Project agent** (`dev-<repo>` profile, on demand) | Plan-mode conversation + issue draft; as a kanban worker: brief → coder → gates → PR | push to the default branch, merge |
| **Coder** (Claude Code / Antigravity, via `code_task.py`) | Writing the code in the task's worktree | anything outside the worktree |
| **Hermes scripts** (deterministic, called *by* Hermes) | The side effects that must be idempotent or bounded: file issue, link project, notify, resource snapshot/enforce | make decisions |

Hermes still decides when to file, queue, kill or notify. The small scripts it calls make each action
**safe to repeat and bounded**, so a model mistake can't file ten issues or kill the wrong process.

## 3. What already exists (reuse, don't rebuild)

| Need | Already on this machine |
|---|---|
| App ↔ Hermes transport | **Hermes gateway `api_server` platform** (`gateway/platforms/api_server.py`): sessions + chat/stream, **runs with an SSE event stream, steer, stop, approval**, and, with `gateway.multiplex_profiles`, **every profile served from the one resident gateway** at `/p/<profile>/…`. It's **not enabled yet** (nothing listens on `:8642`) |
| Per-repo agent + memory | 12 `dev-<repo>` profiles, each with its own `memories/`, `state.db`, `SOUL.md` |
| Projects ↔ repos ↔ board | `hermes project create/add-folder/bind-board`: bound tasks get a deterministic worktree + branch |
| Background work queue | `hermes kanban` (dispatcher inside the gateway): atomic claims, `--workspace worktree`, `--max-runtime`, retries/circuit breaker, `request-review`, `--idempotency-key`, event stream |
| Scheduled/background Hermes jobs | `hermes cron` with `--script`, **`--no-agent`** (script-only watchdog) and **`--monitor-script`** (the agent only wakes when the script's output changes: cheap polling) |
| **Coder adapter** | **`~/.hermes/scripts/code_task.py`**: one entry point for `claude -p` / `agy -p`, auth checks, `--verify` gate, detection of interrupted runs (usage limit, max turns), `--resume`. Hermes already owns this; we extend it, not replace it |
| Gateway on/off | `~/.hermes/scripts/dev_bots.py` (systemd user units `hermes-gateway-dev-*`). Note from its header: *Hermes refuses to start/stop gateways from inside a running gateway* (see §6.6) |
| GitHub | `gh` logged in as **Flexingg**; Hermes `github` skill |
| Push to phone | Bridge FCM `_send_push()` |

## 4. Architecture

```
┌─────────────────────────── Mercury app ───────────────────────────┐
│ Projects │ project: Chat|Plan · Work · Memory · Settings │ Hermes chat │
└──────┬─────────────────────────────────────────────────▲──────────┘
       │ your messages + intents                         │ replies (stream), issue cards,
       ▼                                                 │ task/PR events, FCM
┌──────────────────── bridge (thin relay) ───────────────┴──────────┐
│ /api/v1/projects/* (read)  /api/v1/hermes/* (relay)  POST /api/v1/notify (from Hermes) │
└──────┬───────────────────────────────────────────────────▲────────┘
       │ HTTP + SSE, API_SERVER_KEY                         │ mercury_notify.py
       ▼                                                    │
┌──────────── Hermes default gateway (resident; the orchestrator) ──┴┐
│ api_server (multiplex: /p/<dev-repo>/…)  kanban dispatcher  cron   │
│ skills:  mercury-orchestrator · issue-planner · ship-issue         │
│ scripts: mercury_project · mercury_issue · mercury_notify ·        │
│          mercury_resources · mercury_intake · mercury_ci · code_task│
└──────┬─────────────────────────────────────────────────────────────┘
       │ kanban worker: hermes -p dev-<repo> in worktree issue-N-slug
       ▼
   code_task.py --agent claude|agy   (fallback: the worker codes itself)
     → gates → git push issue-N-slug → gh pr create "Closes #N" → kanban request-review
```

**Why the API server matters:** today the bridge starts a fresh `hermes chat` process per message
(about 2 s of startup and 130 MB+ each time). Through the API server, every project agent runs **inside the one
resident gateway**. "Waking" a project agent costs a session, not a process, and the separate
`dev-*` gateways are no longer needed. That's the memory saving you asked for, and it comes from
Hermes itself. (Whether multiplexing covers everything we need is a Phase 0 item.)

## 5. Hermes-side pieces (new; kept in this repo under `hermes/`, installed into `~/.hermes`)

Keeping them in this repo means they're reviewed, tested and versioned with the app that depends on them.
`hermes/install.sh` symlinks them into `~/.hermes/skills/mercury/` and `~/.hermes/scripts/`.

**Skills**
- `mercury-orchestrator` (default profile): how to route a project message, link a project, take in an
  issue, queue it, watch it, decide wake/sleep/kill within the resource policy, and report to Mercury.
  It includes the project registry format and the never-touch list.
- `issue-planner` (project profiles, Plan mode): stay read-only; ask until scope is clear; check
  duplicates (`gh issue list`); end with a fenced ```` ```issue-draft ```` JSON block (title, body,
  acceptance criteria, labels).
- `ship-issue` (project profiles, kanban worker): read issue + repo `CLAUDE.md`/`AGENTS.md` + project
  memory → brief → `code_task.py --agent <coder> -f brief.md --verify "<gates>"` → up to 3 fix rounds →
  if the coder is unavailable, code it itself → push `issue-N-*` → `gh pr create` (body: what changed,
  which coder, **what was / wasn't verified**) → `kanban request-review` → save lessons to project
  memory. If blocked: `kanban block <reason>`.

**Scripts** (argv only, JSON out, idempotent, unit-tested offline with fake `gh`/`hermes`)
- `mercury_project.py link|unlink|list|set`: clone if missing, reuse or create the `dev-<repo>` profile,
  `hermes project create/add-folder`, board + `bind-board`, `gh label create mercury`, and write the
  registry `~/.hermes/mercury/projects.json` (`repo, path, profile, board, coder, gates,
  idleSleepMinutes`). Unlinking never deletes the repo, profile or memory.
- `mercury_issue.py file --project X --draft draft.json`: `gh issue create --label mercury`, then
  `kanban create … --project --workspace worktree --branch issue-N-slug --assignee dev-X --skill
  ship-issue --idempotency-key <repo>#N --max-runtime 2h`. Running it twice returns the same issue and task.
- `mercury_intake.py`: `gh issue list --label mercury` across linked repos. It prints only issues that
  aren't queued yet. Used as a cron **`--monitor-script`**, so the orchestrator only wakes when there's
  something new.
- `mercury_ci.py`: for tasks in `review`, PR state + `gh pr checks` + the APK artifact of the head
  commit's run. It's a monitor script too, so the orchestrator wakes on change and decides: notify
  "ready", send the task back once on red CI, or mark it "needs you".
- `mercury_resources.py snapshot|enforce`: free RAM, agent processes (profile, RSS, age, owner).
  `enforce` applies the **hard floor** (§6.6): run as a cron **`--no-agent`** watchdog every minute. It
  can only ever act on processes it can attribute to kanban workers or coder runs.
- `mercury_notify.py --kind ready|needs_you|info --project X --title … --body … [--url] [--apk]`:
  `POST /api/v1/notify` on the bridge, which is the only way anything reaches the phone. The bridge
  token comes from the Hermes process environment and is never passed as an argument.
- `code_task.py` (existing), extended: worktree-only writes, environment scrub (`*_TOKEN`,
  `*_API_KEY`), a final JSON result line (`{agent, rc, interrupted, verify_rc, session_id}`), and a
  branch-unchanged check after the coder exits.

**Cron jobs** (created by `hermes/install.sh`, owned by the default profile)
- `mercury-intake`, every 2 min, monitor-script `mercury_intake.py`, skill `mercury-orchestrator`
- `mercury-ci`, every 2 min, monitor-script `mercury_ci.py`, skill `mercury-orchestrator`
- `mercury-resources`, every 1 min, `--no-agent`, `mercury_resources.py enforce`

## 6. Flows

### 6.1 Link a repo (opt-in)
App → **Link repos** sheet: the list comes from a bridge read view (`gh repo list`), and you pick a repo
and its coder. The app sends one intent to the orchestrator: *link flexingg/X, coder claude*. The
orchestrator runs `mercury_project.py link` and confirms in its chat. The project appears in Projects.
**hermes-mobile: coder Claude Code, fallback Hermes.**

### 6.2 Chat / Plan
Project chat goes through the bridge to the API server as that project's profile. **Plan** mode starts
the turn with the `issue-planner` skill and a read-only toolset. When the reply contains an
`issue-draft` block, the app renders the **Issue card** (editable; Refine / Create issue). **Create
issue** sends an intent to the project agent: *file this draft (JSON attached)*. The agent runs
`mercury_issue.py file`, and the card updates to "#42 filed · queued". Work starts immediately (decided).

### 6.3 Issues filed on GitHub
Label an issue `mercury` → within about 2 minutes `mercury-intake` wakes the orchestrator, which queues it
through the same `mercury_issue.py` path (idempotency key `<repo>#N`, so nothing is queued twice).
Removing the label before a worker claims it cancels the task.

### 6.4 Execution
The kanban dispatcher claims the task and runs a `dev-<repo>` worker in worktree `issue-N-slug` with
`ship-issue` (§5). The worktree gets a **`pre-push` hook** that allows only fast-forward pushes to
`refs/heads/issue-*`. (No branch protection on GitHub, decided. The hook can be bypassed with
`--no-verify`, so it's a strong guard, not a guarantee.)

### 6.5 Ready for testing
`mercury-ci` wakes the orchestrator when a PR's state changes. **Ready** = PR open + worker's gates
passed + CI green (or no CI). For Flutter repos, `gh run download` fetches the APK artifact into
`~/.hermes/mercury/apks/`, which the bridge serves through its authenticated `/api/v1/files`. The
orchestrator calls `mercury_notify.py --kind ready … --url <pr> --apk <path>`, and the phone shows
*"hermes-mobile #42 ready for testing"* with **Open PR** and **Install APK**. If CI goes red, the task goes
back to the worker once, then is marked "needs you".

### 6.6 Resources: wake / sleep / kill
- **Resident:** the default gateway only (decided). With `multiplex_profiles` on, project agents live
  inside it. **Every other gateway is stopped and disabled** (`dev-*` and bot gateways such as
  `buff-patrick`/`homie`); those profiles stay usable on demand through the API server, but their
  messaging-platform presence goes offline.
  - Because *Hermes refuses to stop gateways from inside a gateway*, this one-time switch-over is done
    by `hermes/install.sh` from a normal shell, not by the orchestrator.
- **Wake/sleep** (orchestrator's judgement, via its skill): open a project session when a message or
  task needs it; end idle ones after `idleSleepMinutes`; order the kanban queue ("do #42 before #40").
- **Hard floor** (`mercury-resources`, no LLM): at most **2** concurrent coder runs; under **1.5 GB**
  free, block new dispatch and SIGTERM → requeue the newest coder run; tasks past `--max-runtime` are
  killed by kanban itself. **Never touched:** the default gateway, the bridge, `agy remote-control`, and
  interactive `claude` sessions.
- **Kill switch:** "Pause all" in Mercury sends the orchestrator `hermes pause`. "Resume" sends `hermes resume`.

## 7. Bridge changes (kept thin)

| Route | Kind |
|---|---|
| `GET /api/v1/projects`, `/projects/{id}` | read: registry + kanban counts + agent state |
| `GET /api/v1/projects/{id}/tasks` | read: kanban tasks with the issue/PR/CI fields Hermes recorded |
| `GET /api/v1/github/repos` | read: `gh repo list` for the link sheet |
| `GET /api/v1/agents` | read: `mercury_resources.py snapshot` |
| `POST /api/v1/hermes/{profile}/sessions/{id}/chat` (+ WS stream) | relay → API server `/p/<profile>/…` |
| `POST /api/v1/hermes/intent` `{profile, sessionId, kind, payload}` | relay: a structured message to Hermes (link, file_issue, retry, cancel, pause, resume). Hermes decides and acts |
| `POST /api/v1/notify` | **inbound from Hermes**: FCM push + WS `project_event`. Token-guarded and loopback-only |
| existing memory routes | gain `?profile=` for per-project memory |

A test enforces the thin-bridge rule: it fails if `bridge.py` ever contains `gh issue create`,
`kanban create` or `os.kill`, so the second orchestrator can't quietly come back. The existing `hermes chat`
subprocess path stays as the fallback transport until the API-server path is proven (Phase 1).

## 8. App UI

- **Bottom nav:** **Projects** · Chats · Control · Status · Settings.
- **Projects:** a pinned **Hermes** card (the orchestrator chat; "2 working · 1 ready · 1.9 GB free"),
  then one card per project with a state chip (Idle / Planning / Working / Ready / Needs you) and an
  awake/asleep dot.
- **Project** tabs: **Chat** (`Chat | Plan` segmented button, Issue card), **Work** (issue → task → PR →
  CI → APK timeline; Retry/Cancel go to Hermes as intents), **Memory** (`?profile=`), **Settings** (coder
  Claude Code / Antigravity, gates, idle sleep, unlink; also sent to Hermes as intents).
- **Status → Agents:** the resource snapshot + **Pause all**.
- Same patterns as today: `AppRepository` → `HermesRepository` → `AppState`, Material 3, no demo data.

## 9. Delivery phases (each is one PR with tests; gates quoted in the PR body)

| # | Phase | Deliverable | Verified by |
|---|---|---|---|
| **0** | **Spike** (no app code) | §12: sandbox repo, kanban worktree flow, headless coders via `code_task.py`, gh issue/PR, API server capabilities, RAM numbers | written findings + go/no-go per item |
| **1** | Hermes transport | enable API server + `multiplex_profiles` on the default gateway (**needs you, see §12**); bridge relay routes + WS; app talks to Hermes through it; old subprocess path kept as fallback | pytest against a fake API server; manual chat with `@hermes` and `dev-hermes-mobile` from the phone |
| **2** | Projects (link + chat) | `hermes/` dir + `install.sh`, `mercury_project.py`, `mercury-orchestrator` skill (link part), bridge read views, app Projects tab + project Chat/Memory | pytest (script with fake gh/hermes); flutter analyze/test; link hermes-mobile for real |
| **3** | Plan → issue | `issue-planner` skill, `mercury_issue.py`, Issue card, `file_issue` intent | pytest (idempotency, bad draft); widget test; one real issue on the sandbox repo |
| **4** | Execution | `ship-issue` skill, `code_task.py` extensions, pre-push hook, kanban wiring | pytest for the new `code_task.py` behaviour; **end-to-end on the sandbox repo**: issue → PR by Claude Code |
| **5** | Ready + intake | `mercury_ci.py`, `mercury_intake.py`, `mercury_notify.py`, `/notify`, cron jobs, Work tab, APK install | pytest (monitor output stability, dedup, CI state machine); a real push that installs the APK |
| **6** | Resources | `mercury_resources.py`, watchdog cron, `/agents`, Status → Agents, Pause all; **switch-over: stop + disable non-default gateways** | pytest (policy with fake processes, never-touch list); `free -m` before/after quoted in the PR |
| **7** | Hardening + release | README, runbook, version bump, release APK | CI green, apksigner gate, a real issue on hermes-mobile delivered as a PR |

## 10. Decisions (2026-09-26)

| # | Question | Decision |
|---|---|---|
| 1 | Which repos | Opt-in per repo |
| 2 | Branch protection | No, so a local `pre-push` hook + branch check instead |
| 3 | Coders | Per project: Hermes → Claude Code or Hermes → Antigravity; Hermes is the fallback. **hermes-mobile: Claude Code → Hermes.** Plan mode runs on Hermes |
| 4 | APK in "ready" | Yes, for Flutter repos |
| 5 | Gateways | Stop all except the default Hermes gateway |
| 6 | Auto-execute | Yes, as soon as the issue exists |
| 7 | GitHub-filed issues | Yes, via the `mercury` label |
| 8 | Who orchestrates | **Hermes, through Mercury.** The bridge only relays (v2) |

## 11. Out of scope

Auto-merge, multiple machines, review agents on PRs, iOS, QR pairing, and a native Mercury gateway platform
adapter (a possible later replacement for `/notify`; see `gateway/platforms/ADDING_A_PLATFORM.md`).

## 12. Phase 0 findings (2026-09-26)

Sandbox: private repo `Flexingg/mercury-sandbox`, Hermes profile `dev-mercury-sandbox`, board +
project `mercury-sandbox`. These are kept for Phases 3–4, which test against them.

**End-to-end result: GO.** Issue #1 → `kanban create --project --workspace worktree` → the resident
gateway's dispatcher claimed it by itself (**about 60 s**) → Hermes worker (`dev-mercury-sandbox`, 215 MB)
→ `code_task.py --agent claude` → gate `python3 -m unittest -q` → push → **PR #2**
(`mercury-sandbox/t_109b79f2-issue-1-add-subtract` → `main`), **about 90 s** from claim to PR. I checked it
myself rather than trusting the worker's report: the diff is the minimal correct change, I re-ran the gate
in the worktree (OK), and `main` on the remote is unchanged (`cdecb2a`).

| Item | Result | Consequence for the plan |
|---|---|---|
| Kanban dispatcher (in gateway) | ✅ picks up any board's ready task in about 60 s; worktree + branch created automatically | §6.4 as planned; no extra dispatcher needed |
| Branch naming | Hermes uses `<project>/t_<id>-<slug>`, not `issue-N-*` | the pre-push guard allows `refs/heads/<project>/t_*`; issue number goes in the task body/idempotency key |
| Claude Code headless | ✅ via `code_task.py` (Pro login) | reuse `code_task.py` as planned |
| Antigravity headless | ✅ `agy -p … --output-format json` returns `{"status":"SUCCESS","response":…}` in about 3 s | `code_task.py --agent agy` path is fine |
| `gh` issue/label/PR from host | ✅ | as planned |
| **Worker `HOME`** | ⚠️ kanban workers run with the profile's own `home/`: `~/.hermes/scripts/…` wasn't found and `claude`/`gh` weren't logged in until the worker **improvised** `HOME=/home/hermes` | `ship-issue` must use absolute paths and set `HOME`/`GH_CONFIG_DIR` for the coder and `gh` explicitly. Never leave it to the worker to work out |
| **`dev-*` model provider** | ❌ all `dev-*` profiles use `nous` / `deepseek/deepseek-v4.1-flash`, and **Nous Portal credits are exhausted**, so every project agent fails. The default profile (`deepseek` provider direct) works | **decision needed (§13)**; the sandbox profile was switched to `deepseek`/`deepseek-v4-flash` and works |
| **SimpleFIN MCP writes finance data into the cwd** | ❌ `Simplefin_Android_Finances/hermes-mcp-server/src/storage.ts:39` uses `process.cwd()/data`, so every agent started in a repo drops `data/transactions.json` (397 KB) etc. into it. It happened in the sandbox worktree (untracked, not pushed). A scan of every local repo's current files found no leak (history not scanned) | **fix before Phase 4**: give the MCP server a fixed data dir (and/or drop it from `dev-*` profiles), and `ship-issue` stages **named files only**, never `git add -A` |
| Kanban end state | the task went to `done`, not `review`, because my test body didn't call `request-review` | `ship-issue` must end with `kanban request-review` so `mercury-ci` can follow it |
| API server + multiplex | 📖 read, not run: supported feature (`gateway.multiplex_profiles`, per-profile secret scopes, `docs/profile-routing.md`: "instead of running N gateways, run one"). Needs `API_SERVER_KEY` in the default profile's `.env` and a gateway restart | **needs you (§13)**, since it's a secret and a restart of the live `@hermes` bot |
| RAM | default gateway 545 MB; each extra gateway about 130–200 MB idle; a kanban worker 215 MB while running; agy remote-control 689 MB | confirms §6.6 |

## 13. Calls made (2026-09-26): all three done

1. **`dev-*` provider:** all 12 `dev-*` profiles now use `deepseek` / `deepseek-v4-flash` (old configs
   backed up); each answered a test prompt; the 4 running `dev-*` gateways were restarted.
2. **API server:** enabled on the default gateway via `API_SERVER_KEY`/`HOST`/`PORT` in `~/.hermes/.env`
   (generated, never printed), bound to **127.0.0.1:8642**. Verified: 401 without the key, 200 with it, and a
   real chat completion answered by `@hermes`. **Multiplexing is NOT on yet.** Enabling it makes the
   default gateway also connect every other profile's chat bots (`_start_secondary_profile_adapters`), which
   would double-answer while their own gateways run. It has to land together with stopping those gateways
   (the §6.6 switch-over), so it moves from Phase 1 to that switch-over. Note: multiplexing would keep those
   bots **online** inside the one gateway rather than offline, which is cheaper than their current separate
   processes.
3. **SimpleFIN data dir:** `hermes-mcp-server/src/storage.ts` now resolves `baseDir` → `FINANCE_DATA_DIR` →
   the package's own `data/` (already gitignored), never the cwd, with `src/storage.test.ts` (4 tests;
   the default-dir test fails against the old logic). Built; all gateways restarted onto it; a run from an
   empty directory leaves it empty. Uncommitted in the SimpleFIN repo. **Stale copies from before the fix**
   (not deleted, not created by this work): `~/data`, `~/.hermes/data`, `~/.hermes/hermes-agent/data`
   (ignored), `hermes-mobile/data` and `hermes-mobile/server/data` (ignored), and `data/` in 10 profile dirs.

## 14. Phase 1 result (2026-09-26, branch `feat/hermes-api-transport`)

- The bridge sends default-profile chat turns (`POST /sessions/{id}/messages`, `POST /chat/start`) to the API
  server (`server/hermes_api.py`) and maps its SSE events onto the **unchanged** app WebSocket contract, so the
  installed APK benefits with no app release. Other profiles, image turns, and an unavailable API server use
  the CLI as before. A turn that fails after part of the reply was shown is reported, not re-run.
- **Live, measured** (throwaway bridge on :9131, real `state.db` + API server): a turn takes 1.6–2.4 s,
  versus 10.7 s for the same turn through `hermes chat`; history carries across turns; messages persist
  in `state.db`; new chats list under `hermes`.
- Gates: pytest 62 passed; 7 new mutations proven (plus both full suites green again); `contract_check` ok;
  `flutter test` green (the app is unchanged).
- **Not yet:** project (`dev-*`) chats through the API server need multiplexing (§13.2) and are part of the
  switch-over.

## 15. Switch-over (2026-09-26): done

- **Root cause of "chats keep failing" on the phone** (found while doing this): the bridge runs app chats as
  `MER_CHAT_PROFILE=lumen`. (1) `lumen` and the five other non-`dev` profiles were still on the exhausted Nous
  route, so they're now switched to direct DeepSeek (backed up, each tested). (2) Hermes stores a profile's chats in
  **that profile's** `state.db`, but the bridge only read the default one, so app-started chats never listed
  or reloaded. The bridge now resolves each chat's owning profile (second commit on PR #1).
- `gateway.multiplex_profiles: true` on the default gateway. All 17 secondary gateway units are stopped **and
  disabled**. In each of the 19 secondary profiles, `platforms.mattermost/webhook/api_server.enabled: false`
  (configs backed up), so **`@hermes` is the only Mattermost bot**, per decision 5. Each profile got its own
  generated `API_SERVER_KEY` (the gateway authenticates `/p/<profile>/` with that profile's key and refuses the
  default key there, which was verified live both ways).
- Side effect fixed: `@hermes`'s webhook listener had been failing to bind :8644 (1,432 retries) because a `dev-*`
  gateway held the port.
- **Known leftover:** `homie`'s Home Assistant adapter still connects inside the gateway. Hermes' `HASS_TOKEN` loader
  forces the platform on and ignores `enabled: false` (`gateway/config.py:2234`, unlike Mattermost). It is inert:
  with no `watch_*` filters every event is dropped (`adapter.py:310`), so it triggers no agent turns.
- Cron: the gateway now ticks cron for all 20 profiles. No secondary profile had an active recurring job.

## 16. Phases 2–6 (2026-09-26, branch `feat/projects`)

Built and installed. The live run on `mercury-sandbox`, driven through the bridge as the app does it,
went: `link` (Hermes, 11 s) → `set gates` (Hermes ran them to confirm) → Plan chat (35 s, read-only,
checked for duplicates) → **Create issue** (#3 filed and queued) → worker (`prepare` → Claude Code →
gates → `publish`) → PR #4 → `mercury-ci` → **ready push**. What the run found and fixed: projects are
per profile in Hermes (scripts now always act as the default profile); gate detection; the `#N` title
prefix; a moved project's primary folder; `hermes cron create` exits 0 when it refuses a job.

Differences from §5–§7, all deliberate:
- Intake, CI follow-up and the RAM floor are `--no-agent` cron jobs: deterministic, no model call
  every two minutes. The orchestrator model handles conversation: linking, plans, your requests.
- Plan mode is read-only **by instruction** (a per-turn system message plus the skill): the API server
  has no per-request toolset override.
- Test builds: for repos whose CI doesn't build PRs (lumen), the worker's own gate build is kept as
  the PR head's APK.
- Concurrency is Hermes' own `kanban.max_in_progress: 2`.

Known limits: Home Assistant under `homie` ignores `enabled: false` (Hermes bug, inert). The app's
push for "ready" uses the existing FCM path, so it needs the phone registered as before.

## 13a. Original questions (for the record)

1. **`dev-*` model provider:** switch every `dev-*` profile to the direct `deepseek` provider (what `@hermes`
   uses and what works now), or top up Nous Portal?
2. **API server on the default gateway:** OK to enable it (`API_SERVER_KEY` added to
   `~/.hermes/.env`, `gateway.multiplex_profiles: true`, bound to `127.0.0.1` so only the bridge can
   reach it) and restart `@hermes` once? You can generate the key yourself, or let the install script
   generate it without printing it.
3. **SimpleFIN MCP data dir:** fix it in the SimpleFIN repo (read the data dir from an env var with a fixed
   default, e.g. `~/.hermes/simplefin-data`), or just remove that MCP server from the `dev-*` profiles?
