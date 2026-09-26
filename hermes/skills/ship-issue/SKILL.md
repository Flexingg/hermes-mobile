---
name: ship-issue
description: "Kanban worker: take a Mercury issue from its worktree to a reviewed-ready PR via the project's coder."
version: 1.0.0
author: Mercury (hermes-mobile)
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Mercury, Kanban, Coding-Agent, GitHub, PR]
    related_skills: [claude-code, antigravity-cli, github-pr-workflow]
---

# Ship a Mercury issue

You are the kanban worker for one GitHub issue. Your cwd is the task's own git
worktree, on the task's own branch. **You orchestrate; the project's coder
(Claude Code or Antigravity) writes the code.** You write code yourself only when
the coder is unavailable.

The task body gives you: `project`, `repo`, `coder`, `gates`, the issue number, URL
and text. Your kanban task id is in your task context (it looks like `t_1a2b3c4d`).

All helper scripts are at absolute paths. Your `HOME` is not the real home, so
never use `~` for them:

    B=@BIN@

## Steps

1. **Prepare** (installs the push guard for this worktree, records the task):

       python3 $B/mercury_ship.py prepare --project <project> --task <task-id> --worktree "$PWD"

2. **Understand.** Read the issue text, the repo's `AGENTS.md` / `CLAUDE.md` / `README`,
   and your memory for this project. Look at the code the issue touches.

3. **Write the coding brief** to `/tmp/mercury-<task-id>-brief.md` (never inside the
   worktree, or it would be committed). Include:
   - the issue title, text and acceptance criteria;
   - the repo rules you found (quote the relevant lines);
   - exactly where the change goes, if you know;
   - constraints: stay on the current branch; **do not commit, push, or open PRs**;
     don't touch `.env`, keystores, `data/` dumps or anything secret; add or update
     tests the way the repo already does; run `<gates>` before finishing.

4. **Run the coder** (it also runs the gates and checks the branch):

       python3 $B/mercury_code.py run --project <project> --worktree "$PWD" --brief /tmp/mercury-<task-id>-brief.md

   Read the JSON:
   - `ok: true` → go to step 6.
   - `coderStatus: "unavailable"` → the coder can't run (not installed, usage limit).
     Implement the change yourself with your file tools, then run
     `python3 $B/mercury_code.py gates --project <project> --worktree "$PWD"`. You are
     now the coder: say `--coder hermes` in step 7.
   - `gates.passed: false` → write a follow-up brief with the failing tail from
     `gates.tail` and what to fix, and run step 4 again.
   - `branchOk: false` → stop: go to **Blocked**.
   - `neverCommit` not empty → those files will be left out of the commit. Make sure
     the change doesn't depend on them.

   At most **3** coder rounds. Still failing → **Blocked**.

5. **Check the work yourself.** `git diff` in the worktree. The coder's report is
   not evidence; the gate result and the diff are.

6. **Write the PR notes** to `/tmp/mercury-<task-id>-notes.md`:

       ## What changed
       - ...
       ## Verified
       - `<gates command>`: passed (quote the summary line from gates.tail)
       ## Not verified
       - ... (be explicit, e.g. "not run on a device")

7. **Publish** (stages only the changed files, commits, pushes, opens the PR, moves
   the task to review):

       python3 $B/mercury_ship.py publish --project <project> --task <task-id> --worktree "$PWD" \
         --title "<issue title>" --notes /tmp/mercury-<task-id>-notes.md --coder <claude|agy|hermes>

8. Save anything durable you learned about this repo to memory (build quirks,
   test commands). Reply with the PR URL. **Do not** mark the task complete yourself:
   publish moved it to review, and Mercury follows CI from there.

## Blocked

When a person is needed (ambiguous issue, gates that won't pass after 3 rounds,
branch guard failed, missing credentials):

    python3 $B/mercury_ship.py block --project <project> --task <task-id> --reason "<one clear sentence>"

## Never

- `git push` yourself, `--force`, `git add -A`, merging, or pushing to the default branch.
- Committing secrets, `.env`, keystores or `data/*.json` dumps.
- Claiming something was verified that you did not run.

## When CI sends the task back

A comment says which checks failed. Fix it on the same branch (steps 3–7).
`publish` reuses the open PR.
