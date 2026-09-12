# R15-1 · `POST /api/v1/coach/sync-logs` — Hermes-driven log reconciliation

Repo: `hermes-mobile` (`server/bridge.py`). Counterpart of launcher Round 15 (docs/24 in the lumen repo).

## Why

Deterministic on-device parsing can't classify natural-language entries or resolve nutrition. The
Hermes agent can: it has the **SparkyFitness MCP** (verified working under the `lumen` profile —
`hermes -p lumen chat -q "…"` successfully read the check-in diary) plus web search. So the launcher
sends it the day's note lines and Hermes does the thinking and the writes.

## Verified facts (use exactly)

- Invocation that works: `/home/hermes/.local/bin/lumen chat -q "<prompt>"` (wrapper = `hermes -p lumen`),
  or `hermes -p lumen chat -q "<prompt>"`. Runs headless, ~15–60 s, and calls MCP tools.
- `sparky_manage_checkin`: `log_biometrics(entry_date, weight, weight_unit:"kg"|"lbs"|"g", height?, steps?, …)`, `list_checkin_diary(entry_date?)`.
- `sparky_manage_food`: `log_water(amount_ml, entry_date)`, `search_food(food_name, search_type:"exact"|"broad", limit)`,
  `lookup_food_nutrition(food_name, provider_type?:"internal"|"openfoodfacts"|"usda"|"fatsecret"|…")`,
  `log_food(food_name, quantity, unit, meal_type:"breakfast"|"lunch"|"dinner"|"snacks", entry_date, food_id?, variant_id?)`,
  `create_food(food_name, calories, protein, carbs, fat, brand?, …)`, `list_diary(entry_date?)`,
  `delete_entry(entry_id, entry_type:"food_entry")`, `update_entry(entry_id, entry_type, quantity, unit)`.
- `log_food` **requires the food to exist in the user's catalog** (`Error [VALIDATION]: Food "X" not found`),
  so resolve/create first.
- `search_food` returns text with `ID: <uuid> | Variant: <uuid>`; `list_diary` returns blocks ending
  `ID: <uuid> | Type: food_entry`.
- 1 oz = 29.5735 ml.

---

## The endpoint

`POST /api/v1/coach/sync-logs` (Bearer `BRIDGE_TOKEN`, under `/api/v1` so the existing middleware guards it).

**Request**
```json
{
  "date": "2026-09-12",
  "entries": [
    {"lineIndex": 1, "time": "5:00 AM", "text": "213.8 lbs", "marker": null},
    {"lineIndex": 5, "time": "6:51 AM", "text": "two scoops of muscle milk genuine protein powder strawberries and cream", "marker": null},
    {"lineIndex": 0, "time": "5:00 AM", "text": "20 oz of water", "marker": {"kind": "water", "id": "5d30811c-…", "value": 591.5}}
  ],
  "dryRun": false,
  "timeoutSeconds": 180
}
```
- `entries`: the bullet lines the launcher parsed (time + text + any existing marker). `lineIndex` is an
  opaque identifier the launcher uses to map results back — echo it verbatim.
- If `entries` is empty → return `{"ok":true,"results":[],"summary":{…0s…}}` without spawning anything.

**Behaviour**
1. Build a strict prompt and spawn `hermes -p lumen chat -q <prompt>` (async subprocess, capture stdout,
   hard timeout `timeoutSeconds`, default 180). The prompt must instruct the agent to:
   - **Classify** each entry: `weight` (`213.8 lbs`, `97 kg`) | `water` (`20 oz of water`, `500 ml water`)
     | `food` (anything consumed) | `ignored` (tasks `- [ ]`, headers, notes, mood/sleep prose).
   - **Weight** → `sparky_manage_checkin` `log_biometrics(entry_date, weight=<number>, weight_unit="lbs"|"kg")`.
   - **Water** → `log_water(amount_ml = oz × 29.5735, entry_date)`.
   - **Food** → resolve nutrition in this priority order, and say which source it used:
     1. the user's own history (`search_food`, internal — reuse what they logged before);
     2. `lookup_food_nutrition(name)`;
     3. `search_food(name, "broad")` → log with the returned `food_id`/`variant_id`;
     4. a **web search** for branded/packaged items the databases don't know;
     5. as a last resort `create_food` with a clearly-labelled best estimate.
     Then `log_food(...)` with the meal type derived from the entry's time
     (breakfast <11:00, lunch <15:00, dinner <20:00, else snacks; use `snacks` if no time).
     Parse leading quantities/units (`1 egg` → 1 piece, `two scoops of X` → 2 scoop, `12 oz of X` → 12 oz,
     `half scoop` → 0.5 scoop; default `1 serving`).
   - **Existing markers**: if a marker's line value changed → replace that record (delete + re-log, or
     `update_entry` when only quantity/unit changed); if a marker's line is absent from `entries` → delete
     that record. **A 404 / "not found" on any delete = already gone = success**, never a failure.
   - Never invent ids — every `sparkyId` must come from an actual MCP response.
   - **Write the final answer as strict JSON** to the file path given in the prompt
     (`/tmp/lumen-sync-<uuid>.json`) and also reply with a one-line summary.
2. Read that file, validate it, return it as the HTTP response. If the agent wrote nothing valid,
   return `{"ok":false,"error":"agent produced no result","stdout":"<tail>"}` with HTTP 502.
3. Never log or return the Sparky/bridge token.

**Required agent output (strict JSON)**
```json
{
  "ok": true,
  "results": [
    {"lineIndex": 1, "kind": "weight", "action": "created", "sparkyId": null, "value": "213.8 lbs",
     "detail": "logged 212.0 lbs check-in (converted)"},
    {"lineIndex": 5, "kind": "food", "action": "created", "sparkyId": "c192a028-…", "value": "2 scoop",
     "detail": "usda match: Muscle Milk powder"}
  ],
  "summary": {"created": 2, "updated": 0, "deleted": 0, "skipped": 0, "failed": 0},
  "messages": ["1 entry ignored (task line)"]
}
```

**Also**: `GET /api/v1/coach/sync-logs/health` returning `{"ok":true,"profile":"lumen","mcp":true}`
(a cheap readiness probe the launcher can call before relying on the endpoint).

**Verify before committing** (do NOT restart the live service on `:9130`):
- Syntax check + boot a throwaway instance (`PORT=9131 BRIDGE_TOKEN=testtoken`).
- `POST /api/v1/coach/sync-logs` with an empty `entries` list → 200, zeros.
- `POST` with one harmless entry (`{"lineIndex":0,"time":"9:00 AM","text":"1 test apple","marker":null}`)
  and `dryRun: true` if you implement it — otherwise verify the agent spawn path and that a missing/invalid
  agent result yields a clean 502 rather than a hang.
- 401 without a token.
- Commit + push; report the exact request/response you observed.
