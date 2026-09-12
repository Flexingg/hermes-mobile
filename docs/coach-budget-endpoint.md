# 19 · Coach budget endpoint + scheduled heads-up (Hermes Mobile bridge)

Repo: `hermes-mobile` (`server/bridge.py`). Complements launcher Round 9 (docs/18 in the lumen repo),
which shows the budget in-app. This adds a server-side source of truth so a schedule, Tasker, or any
client can trigger a real heads-up when the user is not in the launcher.

## Verified API facts (SparkyFitness)

- `GET {SPARKY_BASE_URL}/api/goals/for-date?date=YYYY-MM-DD` → `UserGoal`:
  `calories`, `protein`, `carbs`, `fat`, `water_goal_ml` (numbers).
- `GET {SPARKY_BASE_URL}/api/food-entries/nutrition/today?date=YYYY-MM-DD` → `NutritionSummary`:
  `total_calories`, `total_protein`, `total_carbs`, `total_fat`.
- Auth: `Authorization: Bearer <SPARKY_TOKEN>`.
- Real values for this user: 2000 kcal / 150 P / 180 C / 75 F / 3548.82 ml.

---

## R10-1 — `GET /api/v1/coach/budget` + `POST /api/v1/coach/push`

> 1. New env: `SPARKY_BASE_URL` (default `https://fit.randalls.cc`), `SPARKY_TOKEN`,
>    optional `MER_COACH_PUSH_TIMES` (e.g. `"13:30,17:30"`, local time) and `MER_COACH_TZ`
>    (default system tz). Never log or return the token value.
> 2. `GET /api/v1/coach/budget?date=YYYY-MM-DD` (defaults to today; token-guarded — it lives under
>    `/api/v1` so the existing auth middleware covers it). Fetch goals + today's nutrition and return:
>    ```json
>    {"date":"2026-09-12","consumedKcal":1450,"goalKcal":2000,"remainingKcal":550,"percent":72.5,
>     "proteinConsumed":95.0,"proteinGoal":150.0,"proteinRemaining":55.0,
>     "waterMl":1200.0,"waterGoalMl":3548.82,"waterRemainingMl":2348.82,
>     "level":"WATCH","message":"🟡 1,250 / 2,000 kcal · 750 left (105g protein to go)"}
>    ```
>    - `level` uses the same rules as the launcher: `≥60% WATCH`, `≥85% NEAR_LIMIT`, `≥100% OVER`,
>      else `ON_TRACK`; add `MIDDAY_CHECK` when it's past 12:00 local and consumed > 0.
>    - Tolerate missing fields (nulls) and non-2xx from Sparky. If `SPARKY_TOKEN` is unset or Sparky is
>      unreachable → `503` with `{"error":"sparky not configured"}` / `{"error":"sparky unreachable"}`.
>      Do not 500.
>    - Use round numbers in `message` (no trailing `.0`), format kcal with thousands separators.
> 3. `POST /api/v1/coach/push` — compute the same budget and deliver it with the existing
>    `_send_push(title, body, data)` helper (title e.g. `Lumen Coach`, body = the message, data
>    `{"type":"coach_budget"}`). Body may include `{"force": true}`. Return
>    `{"ok":true,"devices":<n>,"message":"…"}`; if there are no registered devices, return
>    `{"ok":false,"devices":0,"error":"no registered devices"}` (still HTTP 200).
> 4. **Optional scheduler** (only if clean): if `MER_COACH_PUSH_TIMES` is set, start one asyncio
>    background task on app startup that wakes every ~60s and, when the local time matches a
>    configured slot and that slot hasn't fired today, runs the push. Keep a per-day fired-set so a
>    slot fires once; never let an exception kill the task or the server; log at INFO. If this can't be
>    done cleanly, skip it and say so — the endpoint alone is the deliverable (a cron can call it).
> 5. Use only libraries already available in the bridge environment (stdlib `urllib.request` is fine —
>    no new dependencies). Keep the existing routes/auth/behaviour untouched.
> 6. **Verify** on a throwaway instance (`PORT=9131 BRIDGE_TOKEN=testtoken ...`): 401 without a token;
>    with `SPARKY_TOKEN` unset → 503; with the token set → 200 and a sane `remainingKcal`
>    (`goal - consumed`), and `POST /api/v1/coach/push` returning the devices count. Do NOT restart or
>    disturb the live `hermes-bridge.service` on `:9130`. Commit + push.

Acceptance: `GET /api/v1/coach/budget` returns the budget with a human message; `POST /api/v1/coach/push`
delivers it through the existing push helper; unconfigured Sparky returns 503 (never 500); nothing else
regresses.
