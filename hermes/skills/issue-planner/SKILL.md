---
name: issue-planner
description: "Mercury Plan mode: shape one GitHub issue with the user, read-only, ending in an issue-draft block."
version: 1.0.0
author: Mercury (hermes-mobile)
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Mercury, Planning, GitHub, Issues]
    related_skills: [github-issues, ship-issue]
---

# Plan an issue with the user

Mercury's **Plan** mode: you and the user turn an idea into one well-scoped GitHub
issue. Once it is filed, a worker ships it as a PR in the background, so the issue
is the whole brief. Make it good.

Every Plan-mode message starts with a header like
`[Mercury Plan · project lumen-launcher · Flexingg/lumen-launcher]`. Use that
project id and repo. Helper scripts are at absolute paths (`B=@BIN@`).

## Rules

- **Read-only.** Read and search the code, `git log`, and
  `gh issue list -R <repo> --search "<words>"` for duplicates. Do not edit files,
  run builds, commit, or push. Nothing changes until the issue is filed.
- Ask what you need, a couple of questions at a time. Don't interrogate: propose
  sensible defaults and let the user correct them.
- **One PR's worth.** If it's bigger, propose splitting it and plan the first part.
- Point at real code: files, functions, screens, by name.
- If a similar issue exists, say so and link it before drafting a new one.

## The draft

When the scope is clear, end your reply with exactly one fenced block:

    ```issue-draft
    {"title": "Imperative, specific, under 80 characters",
     "body": "## Why\n...\n\n## What\n...\n\n## Notes for the implementer\n- files: ...",
     "acceptance": ["Observable, testable criterion", "..."],
     "labels": ["enhancement"]}
    ```

Mercury shows it as an editable card with **Refine** and **Create issue**. Refine =
the user keeps talking; send an updated block when anything changes.

## Filing

When a message says `[Mercury: file issue]` followed by draft JSON, the user has
tapped **Create issue**. File exactly that draft (it may have been edited):

    cat > /tmp/mercury-draft.json <<'JSON'
    <the draft JSON from the message, verbatim>
    JSON
    python3 $B/mercury_issue.py file --project <project> --draft /tmp/mercury-draft.json

Reply with the issue link and "queued". Filing twice is safe: the script returns the
same issue. If it fails, say exactly what the error was.
