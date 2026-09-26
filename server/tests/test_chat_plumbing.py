"""Hermes' CLI chrome must never reach a chat bubble as the agent's words.

The screenshot that prompted this: the Assistant panel showed "Session
20260926_115626_c2787f found but has no messages. Starting fresh.", the resume
hint and the "Title:/Duration:/Messages:" summary as the assistant's reply. Every
line matched none of the status prefixes, so the classifier called it an answer.
"""
from __future__ import annotations

import pytest

import bridge

# The banner exactly as the CLI printed it (screenshot, 2026-09-26).
SCREENSHOT = """Session 20260926_115626_c2787f found but has no messages. Starting fresh.
🔗 attaching 1 image(s) natively (model supports vision):
ac095b29_scaled_f3138f07-172d-4995-b35a-382046529d496367632180177757070.jpg
Resume this session with:
 hermes --resume 20260926_115626_c2787f
 hermes -c "Assistant"
Title:    Assistant
Duration: 19s
Messages: 2 (1 user, 0 tool calls)
"""


@pytest.mark.parametrize("line", SCREENSHOT.strip().splitlines())
def test_every_line_of_the_banner_is_plumbing(line):
    assert bridge.is_cli_plumbing(line), line


@pytest.mark.parametrize("kind", ["answer", "thinking", "technical", "skip"])
def test_the_banner_lines_are_never_answers(kind):
    state = {"thinking": False}
    got = [bridge._classify_line(line, state) for line in SCREENSHOT.strip().splitlines()]
    assert "answer" not in got, got
    assert got.count("meta") == 9


def test_the_classifier_still_lets_a_real_answer_through():
    state = {"thinking": False}
    assert bridge._classify_line("You have 1,310 kcal left today.", state) == "answer"
    assert bridge._classify_line("⏸ working", state) == "technical"
    assert bridge._classify_line("   ", state) == "skip"
    # and an answer that merely mentions a session verb is left alone
    assert bridge._classify_line("Session state is stored in state.db.", state) == "answer"


def test_strip_keeps_only_the_answer():
    assert bridge.strip_cli_plumbing("Here is what I found.\n" + SCREENSHOT) == "Here is what I found."
    assert bridge.strip_cli_plumbing("Two things:\n\n1. Fasting") == "Two things:\n\n1. Fasting"
    assert bridge.strip_cli_plumbing("") == ""


def test_the_facts_travel_as_meta_instead_of_text():
    meta = bridge.parse_cli_plumbing(SCREENSHOT.splitlines())
    assert meta == {
        "sessionId": "20260926_115626_c2787f",
        "note": "no messages in this session yet — started fresh",
        "resumeCommand": "hermes --resume 20260926_115626_c2787f",
        "title": "Assistant",
        "duration": "19s",
        "messages": "2 (1 user, 0 tool calls)",
    }
    assert bridge.parse_cli_plumbing(["just an answer"]) == {}


def test_the_tasker_answer_is_cleaned_too():
    stdout = f"Query: hello\nInitializing agent...\nThe answer.\n\n{SCREENSHOT}"
    assert bridge._extract_answer(stdout) == "The answer."


# A real turn from this Hermes version (`cli.py`), captured live:
#   hermes chat -q "Run the terminal tool: echo bridge-probe. Then reply with
#   exactly: PROBE-OK" --pass-session-id
REAL_TURN = """Query: Run the terminal tool: echo bridge-probe. Then reply with exactly:
PROBE-OK
Initializing agent...
────────────────────────────────────────

  ┊ 💻 preparing terminal…
  ┊ 💻 $         echo bridge-probe  0.3s

╭─ ⚕ Hermes ───────────────────────────────────────────────────────────────────╮
PROBE-OK
╰──────────────────────────────────────────────────────────────────────────────╯

Resume this session with:
  hermes --resume 20260926_160619_84d550
  hermes -c "Run echo bridge-probe in terminal"

Session:        20260926_160619_84d550
Title:          Run echo bridge-probe in terminal
Duration:       6s
Messages:       4 (1 user, 2 tool calls)"""


def _classify_turn(text, sent=None):
    state = {"thinking": False}
    if sent is not None:
        state["sent"] = sent
    return [(l, bridge._classify_line(l, state)) for l in text.splitlines()]


def test_a_real_turn_streams_only_the_answer():
    """The reply is inside the ⚕ Hermes panel — not the session banner, and not the
    prompt echoed back over two wrapped lines."""
    sent = "Run the terminal tool: echo bridge-probe. Then reply with exactly: PROBE-OK"
    got = _classify_turn(REAL_TURN, sent)
    visible = [l.strip() for l, kind in got if kind == "answer"]
    assert visible == ["PROBE-OK"]

    kinds = {l.strip(): kind for l, kind in got}
    # the wrapped tail of the echoed prompt is not an answer (it used to be)
    assert got[1][1] == "meta"
    # tool progress stays noise, the banner stays meta
    assert kinds["┊ 💻 preparing terminal…"] == "technical"
    assert kinds["Messages:       4 (1 user, 2 tool calls)"] == "meta"
    assert kinds["╭─ ⚕ Hermes ───────────────────────────────────────────────────────────────────╮"] == "skip"
    # and nothing that is not the reply is ever an answer
    assert [l for l, kind in got if kind == "answer"] == ["PROBE-OK"]


def test_another_kind_of_panel_is_still_not_the_answer():
    """Stash/clarify panels are chrome: collapsible, never the agent's words."""
    text = "╭─ 📌 Stash (2 items) ─────────────╮\n1. first\n2. second\n╰──────────────────────────────────╯\nAfter."
    kinds = [kind for _, kind in _classify_turn(text)]
    assert kinds == ["thinking", "thinking", "thinking", "thinking", "answer"]


def test_the_echo_block_ends_at_initializing():
    """A prompt that wraps ends its echo at "Initializing agent..." — the reply
    that follows is classified normally."""
    sent = ("a very long prompt that wraps onto several lines because of the terminal "
            "width used by the CLI")
    lines = ["Query: a very long prompt that wraps onto several lines because of the term",
             "inal width used by the CLI", "Initializing agent...", "The real answer."]
    got = [kind for _, kind in _classify_turn("\n".join(lines), sent)]
    assert got == ["meta", "meta", "meta", "answer"]


def test_the_echo_guard_gives_up_rather_than_swallowing_output():
    """If the block after "Query:" is longer than anything we sent, it is not an
    echo — it is output, and it must not disappear (e.g. a provider error)."""
    lines = ["Query: hi", "No inference provider configured. Run 'hermes model' to choose a provider",
             "and model, or set an API key in ~/.hermes/.env.", "Goodbye! ⚕"]
    got = [kind for _, kind in _classify_turn("\n".join(lines), "hi")]
    assert got[0] == "meta"
    assert got[1] == "answer" and got[2] == "answer"
