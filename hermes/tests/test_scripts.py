"""Behaviour of the Hermes-side Mercury scripts, run as Hermes runs them."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from conftest import SCRIPTS, git

sys.path.insert(0, str(SCRIPTS))


# -- mercury_project.py ----------------------------------------------------------
def _gh_repo_view(env, name="demo", branch="main"):
    env.respond("gh", ["repo", "view"], json.dumps(
        {"name": name, "nameWithOwner": f"Flexingg/{name}", "defaultBranchRef": {"name": branch}}))


def _installed_skills(env):
    for s in ("issue-planner", "ship-issue"):
        d = env.root / "skills" / "mercury" / s
        d.mkdir(parents=True, exist_ok=True)
        (d / "SKILL.md").write_text("x")


def test_link_reuses_the_existing_clone_and_profile(env, repo):
    _gh_repo_view(env)
    _installed_skills(env)
    git(repo["main"], "remote", "set-url", "origin", "git@github.com:Flexingg/demo.git", env=repo["env"])
    (env.root / "profiles" / "dev-demo").mkdir(parents=True)
    (env.root / "profiles" / "dev-demo" / "config.yaml").write_text("{}")
    env.respond("hermes", ["project", "show"], rc=1)
    rc, out = env.run("mercury_project.py", "link", "Flexingg/demo", "--coder", "agy")
    assert rc == 0, out
    p = out["project"]
    assert (p["path"], p["profile"], p["coder"], p["board"]) == (str(repo["main"]), "dev-demo", "agy", "demo")
    assert out["cloned"] is False and out["profileCreated"] is False
    assert not env.called("hermes", "profile", "create")
    assert env.called("hermes", "kanban", "boards", "create", "demo")
    assert env.called("hermes", "project", "create", "demo")
    assert env.called("gh", "label", "create", "mercury")
    link = env.root / "profiles" / "dev-demo" / "skills" / "mercury" / "ship-issue"
    assert link.is_symlink() and os.readlink(link) == str(env.root / "skills" / "mercury" / "ship-issue")
    assert json.loads((env.root / "mercury" / "projects.json").read_text())["projects"][0]["id"] == "demo"


def test_link_is_idempotent_and_keeps_settings(env, repo):
    _gh_repo_view(env)
    _installed_skills(env)
    git(repo["main"], "remote", "set-url", "origin", "https://github.com/Flexingg/demo", env=repo["env"])
    (env.root / "profiles" / "dev-demo").mkdir(parents=True)
    (env.root / "profiles" / "dev-demo" / "config.yaml").write_text("{}")
    env.respond("hermes", ["kanban", "boards", "list"], "  demo   Demo  (empty)\n")
    env.respond("hermes", ["project", "show"], "board:   demo\n")
    assert env.run("mercury_project.py", "link", "Flexingg/demo", "--gates", "make check")[0] == 0
    first = json.loads((env.root / "mercury" / "projects.json").read_text())["projects"][0]
    rc, out = env.run("mercury_project.py", "link", "Flexingg/demo")
    assert rc == 0, out
    assert out["project"]["gates"] == "make check"
    assert out["project"]["linkedAt"] == first["linkedAt"]
    assert not env.called("hermes", "kanban", "boards", "create")
    assert not env.called("hermes", "project", "create")


def test_new_profile_gets_its_own_api_key(env, repo):
    _gh_repo_view(env)
    _installed_skills(env)
    git(repo["main"], "remote", "set-url", "origin", "git@github.com:Flexingg/demo.git", env=repo["env"])
    home = env.root / "profiles" / "dev-demo"
    # `hermes profile create --clone-from` copies the template's .env, key included
    env.respond("hermes", ["profile", "create"], effects=[
        ["mkfile", str(home / "config.yaml"), "{}"],
        ["mkfile", str(home / ".env"), "MATTERMOST_TOKEN=m\nAPI_SERVER_KEY=TEMPLATE-KEY-TEMPLATE-KEY\n"]])
    env.respond("hermes", ["project", "show"], rc=1)
    rc, out = env.run("mercury_project.py", "link", "Flexingg/demo")
    assert rc == 0, out
    assert out["profileCreated"] is True
    text = (home / ".env").read_text()
    assert "TEMPLATE-KEY" not in text and text.count("API_SERVER_KEY=") == 1
    assert "MATTERMOST_TOKEN=m" in text
    assert oct((home / ".env").stat().st_mode)[-3:] == "600"


def test_link_rejects_bad_input(env):
    assert env.run("mercury_project.py", "link", "not a repo")[1]["ok"] is False
    rc, out = env.run("mercury_project.py", "link", "Flexingg/demo", "--coder", "vim")
    assert rc == 1 and "coder" in out["error"]


@pytest.mark.parametrize("files,expected", [
    ({"pubspec.yaml": ""}, "flutter analyze && flutter test"),
    ({"gradlew": ""}, "./gradlew --no-daemon --max-workers=2 testDebugUnitTest"),
    ({"gradlew": "", "app/src/main/AndroidManifest.xml": ""},   # an Android app: build the test APK too
     "./gradlew --no-daemon --max-workers=2 testDebugUnitTest :app:assembleDebug"),
    ({"package.json": ""}, "npm test"),
    ({"pyproject.toml": "[tool.pytest.ini_options]\n", "tests/test_a.py": ""}, "python3 -m pytest -q"),
    ({"conftest.py": ""}, "python3 -m pytest -q"),
    ({"test_calc.py": ""}, "python3 -m unittest discover -q"),   # the sandbox's layout
    ({"tests/test_a.py": ""}, "python3 -m unittest discover -q -s tests"),
    ({"pyproject.toml": "[project]\n"}, ""),
    ({"README.md": ""}, ""),
])
def test_gates_are_detected_from_the_repo(tmp_path, files, expected):
    import mercury_project
    for name, text in files.items():
        (tmp_path / name).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / name).write_text(text)
    assert mercury_project.detect_gates(tmp_path) == expected


def test_set_and_unlink(env):
    env.project()
    rc, out = env.run("mercury_project.py", "set", "demo", "--coder", "agy", "--gates", "make t")
    assert rc == 0 and (out["project"]["coder"], out["project"]["gates"]) == ("agy", "make t")
    assert env.run("mercury_project.py", "set", "demo", "--coder", "vim")[0] == 1
    rc, out = env.run("mercury_project.py", "unlink", "demo")
    assert rc == 0 and "profile" in out["kept"]
    assert json.loads((env.root / "mercury" / "projects.json").read_text())["projects"] == []


# -- mercury_issue.py --------------------------------------------------------------
DRAFT = {"title": "Add a fasting card", "body": "## Why\nTrack fasts.", "acceptance": ["Card shows hours"],
         "labels": ["enhancement", "nope"]}


def _issue_fakes(env, number=42):
    env.respond("gh", ["label", "list"], json.dumps([{"name": "enhancement"}, {"name": "mercury"}]))
    env.respond("gh", ["issue", "create"], f"https://github.com/Flexingg/demo/issues/{number}\n")
    env.respond("gh", ["issue", "view"], json.dumps(
        {"number": number, "title": DRAFT["title"], "url": f"https://github.com/Flexingg/demo/issues/{number}",
         "state": "OPEN", "body": "text"}))
    env.respond("hermes", ["kanban", "--board", "demo", "create"], json.dumps(
        {"id": "t_0001", "status": "ready", "branch_name": "demo/t_0001-add-a-fasting-card"}))


def test_file_creates_the_issue_and_queues_it(env):
    env.project()
    _issue_fakes(env)
    rc, out = env.run("mercury_issue.py", "file", "--project", "demo", "--draft", "-", stdin=json.dumps(DRAFT))
    assert rc == 0, out
    assert (out["issue"], out["task"], out["duplicateDraft"]) == (42, "t_0001", False)
    create = env.called("gh", "issue", "create")[0]
    assert create["argv"].count("--label") == 2 and "nope" not in create["argv"]  # unknown labels dropped
    assert "- [ ] Card shows hours" in create["stdin"]
    k = env.called("hermes", "kanban", "--board", "demo", "create")[0]["argv"]
    for flag, val in (("--assignee", "dev-demo"), ("--workspace", "worktree"), ("--skill", "ship-issue"),
                      ("--idempotency-key", "Flexingg/demo#42"), ("--project", "demo")):
        assert k[k.index(flag) + 1] == val
    st = env.task_state("t_0001")
    assert (st["issue"], st["phase"], st["project"]) == (42, "queued", "demo")


def test_the_same_draft_files_one_issue(env):
    env.project()
    _issue_fakes(env)
    env.run("mercury_issue.py", "file", "--project", "demo", "--draft", "-", stdin=json.dumps(DRAFT))
    env.board().execute("INSERT INTO tasks VALUES ('t_0001','ready','Flexingg/demo#42',1)").connection.commit()
    rc, out = env.run("mercury_issue.py", "file", "--project", "demo", "--draft", "-", stdin=json.dumps(DRAFT))
    assert rc == 0 and out["duplicateDraft"] is True and out["alreadyQueued"] is True
    assert len(env.called("gh", "issue", "create")) == 1
    assert len(env.called("hermes", "kanban", "--board", "demo", "create")) == 1


@pytest.mark.parametrize("draft,err", [({"body": "x"}, "no title"), ({"title": "x" * 201}, "longer"),
                                       ("[1]", "JSON object")])
def test_bad_drafts_are_refused_before_github(env, draft, err):
    env.project()
    raw = draft if isinstance(draft, str) else json.dumps(draft)
    rc, out = env.run("mercury_issue.py", "file", "--project", "demo", "--draft", "-", stdin=raw)
    assert rc == 1 and err in out["error"]
    assert not env.called("gh", "issue", "create")


def test_closed_issues_are_not_queued(env):
    env.project()
    env.respond("gh", ["issue", "view"], json.dumps({"number": 7, "title": "t", "url": "u", "state": "CLOSED"}))
    rc, out = env.run("mercury_issue.py", "queue", "--project", "demo", "--issue", "7")
    assert rc == 1 and "closed" in out["error"]


def test_cancel_only_touches_unclaimed_tasks(env):
    env.project()
    con = env.board()
    con.execute("INSERT INTO tasks VALUES ('t_run','running','Flexingg/demo#1',1)")
    con.execute("INSERT INTO tasks VALUES ('t_new','ready','Flexingg/demo#2',1)")
    con.commit()
    assert env.run("mercury_issue.py", "cancel", "--project", "demo", "--issue", "1")[1]["cancelled"] is False
    assert env.run("mercury_issue.py", "cancel", "--project", "demo", "--issue", "2")[1]["cancelled"] is True
    assert [c["argv"][-1] for c in env.called("hermes", "kanban", "--board", "demo", "archive")] == ["t_new"]


# -- mercury_code.py -----------------------------------------------------------------
FAKE_CODE_TASK = r'''
import os, sys, json, subprocess
from pathlib import Path
argv = sys.argv
repo = argv[argv.index("-C") + 1]
mode = os.environ.get("FAKE_CODER", "edit")
Path(os.environ["FAKE_DIR"], "coder_env.json").write_text(json.dumps(sorted(os.environ)))
Path(os.environ["FAKE_DIR"], "coder_home").write_text(os.environ.get("HOME", ""))
if mode == "unavailable":
    print("no usable coding agent."); sys.exit(3)
if mode == "limit":
    print("[delegate] INCOMPLETE - You've hit your limit"); sys.exit(2)
Path(repo, "app.txt").write_text("v2\n")
Path(repo, "data").mkdir(exist_ok=True)
Path(repo, "data", "transactions.json").write_text("{}")
if mode == "switch":
    subprocess.run(["git", "-C", repo, "checkout", "-q", "-b", "elsewhere"], check=True)
print("[delegate] exit=0 elapsed=1s meta={'session_id': 'sess-1'}")
print("--- agent report (NOT evidence) ---")
print("done it")
'''


@pytest.fixture
def coder(env, repo):
    (env.root / "scripts").mkdir(parents=True, exist_ok=True)
    (env.root / "scripts" / "code_task.py").write_text(FAKE_CODE_TASK)
    brief = env.tmp / "brief.md"
    brief.write_text("do it")
    env.project(gates="grep -q v2 app.txt")
    return brief


def test_coder_runs_with_the_real_home_and_no_secrets(env, repo, coder):
    rc, out = env.run("mercury_code.py", "run", "--project", "demo", "--worktree", str(repo["wt"]),
                      "--brief", str(coder), GITHUB_TOKEN="x", API_SERVER_KEY="y", MY_SECRET="z",
                      HOME="/profile/home")
    assert rc == 0, out
    assert out["coderStatus"] == "done" and out["gates"]["passed"] is True and out["sessionId"] == "sess-1"
    names = json.loads((env.fake / "coder_env.json").read_text())
    assert not {"GITHUB_TOKEN", "API_SERVER_KEY", "MY_SECRET"} & set(names)
    assert (env.fake / "coder_home").read_text() == str(env.home)
    assert out["neverCommit"] == ["data/transactions.json"]


def test_coder_switching_branch_fails_the_guard(env, repo, coder):
    rc, out = env.run("mercury_code.py", "run", "--project", "demo", "--worktree", str(repo["wt"]),
                      "--brief", str(coder), FAKE_CODER="switch")
    assert rc == 1 and out["branchOk"] is False and "moved" in out["branchProblem"]
    assert out["gates"]["passed"] is False


@pytest.mark.parametrize("mode", ["unavailable", "limit"])
def test_unusable_coder_is_reported_as_unavailable(env, repo, coder, mode):
    rc, out = env.run("mercury_code.py", "run", "--project", "demo", "--worktree", str(repo["wt"]),
                      "--brief", str(coder), FAKE_CODER=mode)
    assert rc == 1 and out["coderStatus"] == "unavailable"


def test_refuses_to_code_on_the_default_branch(env, repo, coder):
    rc, out = env.run("mercury_code.py", "run", "--project", "demo", "--worktree", str(repo["main"]),
                      "--brief", str(coder))
    assert rc == 1 and "refusing" in out["error"]


def test_failing_gates_are_reported(env, repo, coder):
    env.project(gates="echo boom >&2; exit 3")
    rc, out = env.run("mercury_code.py", "run", "--project", "demo", "--worktree", str(repo["wt"]),
                      "--brief", str(coder))
    assert rc == 1 and out["gates"]["rc"] == 3 and "boom" in out["gates"]["tail"]


# -- mercury_ship.py -----------------------------------------------------------------
@pytest.fixture
def shipped(env, repo):
    # the main clone's untracked machine config (an Android SDK path, plus a secret)
    (repo["main"] / "local.properties").write_text("sdk.dir=/opt/android-sdk\nstorePassword=hunter2\n")
    env.project()
    env.root.joinpath("mercury", "hooks").mkdir(parents=True, exist_ok=True)
    hook = env.root / "mercury" / "hooks" / "pre-push"
    hook.write_text((SCRIPTS.parent / "hooks" / "pre-push").read_text())
    hook.chmod(0o755)
    (env.root / "mercury" / "tasks").mkdir(parents=True, exist_ok=True)
    (env.root / "mercury" / "tasks" / "t_abc.json").write_text(json.dumps({"task": "t_abc", "issue": 42}))
    rc, out = env.run("mercury_ship.py", "prepare", "--project", "demo", "--task", "t_abc", "--worktree",
                      str(repo["wt"]))
    assert rc == 0, out
    return repo


def test_push_guard_is_on_the_worktree_only(env, shipped):
    e = shipped["env"]
    assert git(shipped["wt"], "config", "core.hooksPath", env=e).endswith("mercury/hooks")
    main_hooks = subprocess.run(["git", "-C", str(shipped["main"]), "config", "core.hooksPath"],
                                capture_output=True, text=True, env=e)
    assert main_hooks.stdout.strip() == ""  # a person's own clone is untouched


def test_push_guard_refuses_main_and_force(env, shipped):
    e, wt = shipped["env"], shipped["wt"]
    (wt / "app.txt").write_text("hack\n")
    git(wt, "commit", "-qam", "x", env=e)
    main_push = subprocess.run(["git", "-C", str(wt), "push", "origin", "HEAD:main"], capture_output=True,
                               text=True, env=e)
    assert main_push.returncode != 0 and "refusing to push to refs/heads/main" in main_push.stderr
    git(wt, "push", "-q", "origin", "HEAD:refs/heads/demo/t_abc-fix", env=e)
    git(wt, "commit", "-q", "--amend", "-m", "rewritten", env=e)
    forced = subprocess.run(["git", "-C", str(wt), "push", "-f", "origin", "HEAD:refs/heads/demo/t_abc-fix"],
                            capture_output=True, text=True, env=e)
    assert forced.returncode != 0 and "non-fast-forward" in forced.stderr


def test_publish_stages_named_files_pushes_and_opens_the_pr(env, shipped):
    e, wt = shipped["env"], shipped["wt"]
    (wt / "app.txt").write_text("v2\n")
    (wt / "data").mkdir()
    (wt / "data" / "transactions.json").write_text("{}")
    (wt / ".env").write_text("SECRET=1")
    notes = env.tmp / "notes.md"
    notes.write_text("## What changed\n- app")
    env.respond("gh", ["pr", "list"], "[]")
    env.respond("gh", ["pr", "create"], "https://github.com/Flexingg/demo/pull/9\n")
    rc, out = env.run("mercury_ship.py", "publish", "--project", "demo", "--task", "t_abc", "--worktree",
                      str(wt), "--title", "#42 Add a fasting card", "--notes", str(notes), "--coder", "claude")
    assert rc == 0, out
    pr_args = env.called("gh", "pr", "create")[0]["argv"]
    assert pr_args[pr_args.index("--title") + 1] == "Add a fasting card"  # no "#42 " prefix twice
    assert out["committed"] == ["app.txt"]
    # never committed: data dumps, secrets, and the SDK-path file prepare carried over
    assert set(out["notCommitted"]) == {"data/transactions.json", ".env", "local.properties"}
    assert git(shipped["origin"], "log", "-1", "--format=%s%n%b", "demo/t_abc-fix", env=e).splitlines()[0] \
        == "Add a fasting card (#42)"
    body = env.called("gh", "pr", "create")[0]["stdin"]
    assert "Closes #42" in body and "coder: claude" in body
    st = env.task_state("t_abc")
    assert (st["prNumber"], st["phase"], st["ci"]) == (9, "review", "pending")
    assert env.called("hermes", "kanban", "--board", "demo", "request-review", "t_abc")


def test_publish_reuses_an_open_pr(env, shipped):
    wt = shipped["wt"]
    (wt / "app.txt").write_text("v3\n")
    notes = env.tmp / "notes.md"
    notes.write_text("fix")
    env.respond("gh", ["pr", "list"], json.dumps([{"number": 9, "url": "https://github.com/Flexingg/demo/pull/9"}]))
    rc, out = env.run("mercury_ship.py", "publish", "--project", "demo", "--task", "t_abc", "--worktree",
                      str(wt), "--title", "t", "--notes", str(notes))
    assert rc == 0 and out["prNumber"] == 9
    assert not env.called("gh", "pr", "create")


def test_publish_with_nothing_to_ship_fails(env, shipped):
    notes = env.tmp / "notes.md"
    notes.write_text("x")
    rc, out = env.run("mercury_ship.py", "publish", "--project", "demo", "--task", "t_abc", "--worktree",
                      str(shipped["wt"]), "--title", "t", "--notes", str(notes))
    assert rc == 1 and "nothing to publish" in out["error"]


def test_block_records_the_reason(env):
    env.project()
    rc, out = env.run("mercury_ship.py", "block", "--project", "demo", "--task", "t_abc", "--reason", "unclear")
    assert rc == 0
    assert env.task_state("t_abc")["phase"] == "needs_you"
    assert env.called("hermes", "kanban", "--board", "demo", "block", "t_abc")


# -- mercury_notify.py ------------------------------------------------------------------
@pytest.fixture
def bridge(env):
    got = []

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            got.append({"path": self.path, "key": self.headers.get("X-Mercury-Notify-Key"),
                        "body": json.loads(self.rfile.read(n))})
            raw = b'{"ok": true, "pushed": 1}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    (env.root / "mercury").mkdir(parents=True, exist_ok=True)
    (env.root / "mercury" / "notify.key").write_text("nk-123\n")
    yield got, f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def test_ready_is_pushed_once_per_pr_head(env, bridge):
    got, url = bridge
    (env.root / "mercury" / "tasks").mkdir(parents=True, exist_ok=True)
    (env.root / "mercury" / "tasks" / "t_abc.json").write_text(json.dumps({"prNumber": 9, "headSha": "aaa"}))
    args = ("--kind", "ready", "--project", "demo", "--task", "t_abc", "--title", "ready", "--url", "u")
    assert env.run("mercury_notify.py", *args, MERCURY_BRIDGE_URL=url)[0] == 0
    rc, out = env.run("mercury_notify.py", *args, MERCURY_BRIDGE_URL=url)
    assert rc == 0 and out["skipped"] == "already sent"
    assert len(got) == 1 and got[0]["key"] == "nk-123" and got[0]["path"] == "/internal/notify"
    assert got[0]["body"]["kind"] == "ready"


def test_notify_without_a_key_fails_clearly(env):
    rc, out = env.run("mercury_notify.py", "--kind", "info", "--project", "demo", "--title", "t")
    assert rc == 1 and "install.sh" in out["error"]


# -- mercury_intake.py -------------------------------------------------------------------
def test_intake_queues_new_labels_and_cancels_removed_ones(env):
    env.project()
    con = env.board()
    con.execute("INSERT INTO tasks VALUES ('t_old','ready','Flexingg/demo#5',1)")   # label since removed
    con.execute("INSERT INTO tasks VALUES ('t_busy','running','Flexingg/demo#6',1)")  # claimed: leave it
    con.commit()
    env.respond("gh", ["issue", "list"], json.dumps([{"number": 7, "title": "New thing"}]))
    env.respond("gh", ["issue", "view"], json.dumps({"number": 7, "title": "New thing", "url": "u7",
                                                     "state": "OPEN", "body": ""}))
    env.respond("hermes", ["kanban", "--board", "demo", "create"], json.dumps({"id": "t_new", "status": "ready"}))
    p = subprocess.run([sys.executable, str(SCRIPTS / "mercury_intake.py"), "--apply"], capture_output=True,
                       text=True, env=env.environ())
    assert p.returncode == 0, p.stdout + p.stderr
    assert "queued demo #7 New thing -> t_new" in p.stdout
    assert "cancelled demo #5 (t_old)" in p.stdout and "t_busy" not in p.stdout
    quiet = subprocess.run([sys.executable, str(SCRIPTS / "mercury_intake.py")], capture_output=True,
                           text=True, env=env.environ(MERCURY_GH=str(env.tmp / "missing")))
    assert "error demo" in quiet.stdout  # a broken gh is reported, not silent


# -- mercury_ci.py -------------------------------------------------------------------------
def test_ci_summary():
    import mercury_ci
    ok = {"status": "COMPLETED", "conclusion": "SUCCESS", "name": "test"}
    assert mercury_ci.ci_summary([]) == ("none", [])
    assert mercury_ci.ci_summary([ok]) == ("green", [])
    assert mercury_ci.ci_summary([ok, {"status": "IN_PROGRESS", "name": "b"}]) == ("pending", [])
    assert mercury_ci.ci_summary([ok, {"status": "COMPLETED", "conclusion": "FAILURE", "name": "b"}]) == ("red", ["b"])
    assert mercury_ci.ci_summary([{"context": "legacy", "state": "PENDING"}]) == ("pending", [])


def _pr_view(env, sha, conclusion):
    rollup = [{"name": "test", "status": "COMPLETED", "conclusion": conclusion}]
    env.respond("gh", ["pr", "view"], json.dumps({"state": "OPEN", "headRefOid": sha, "url": "pr-url",
                                                   "title": "Add card", "statusCheckRollup": rollup}))


def _review_task(env, **extra):
    env.project()
    (env.root / "mercury" / "tasks").mkdir(parents=True, exist_ok=True)
    st = {"task": "t_abc", "project": "demo", "issue": 42, "prNumber": 9, "phase": "review", "ci": "pending"}
    st.update(extra)
    (env.root / "mercury" / "tasks" / "t_abc.json").write_text(json.dumps(st))


def test_red_ci_goes_back_once_then_needs_you(env, bridge):
    got, url = bridge
    _review_task(env)
    _pr_view(env, "sha1", "FAILURE")
    run = lambda: subprocess.run([sys.executable, str(SCRIPTS / "mercury_ci.py"), "--apply"],  # noqa: E731
                                 capture_output=True, text=True, env=env.environ(MERCURY_BRIDGE_URL=url)).stdout
    assert "sent back to the worker" in run()
    assert env.called("hermes", "kanban", "--board", "demo", "reopen-review", "t_abc")
    assert run() == ""  # same head, same state: silent
    # the worker republishes on a new commit and CI fails again
    st = env.task_state("t_abc")
    st.update(phase="review", ci="pending")
    (env.root / "mercury" / "tasks" / "t_abc.json").write_text(json.dumps(st))
    _pr_view(env, "sha2", "FAILURE")
    assert "needs you" in run()
    assert len(env.called("hermes", "kanban", "--board", "demo", "reopen-review")) == 1
    assert [g["body"]["kind"] for g in got] == ["needs_you"]


def test_green_ci_notifies_ready_with_the_apk(env, bridge, tmp_path):
    got, url = bridge
    _review_task(env)
    _pr_view(env, "sha1", "SUCCESS")
    env.respond("gh", ["run", "list"], json.dumps([{"databaseId": 77, "status": "completed", "conclusion": "success"}]))
    env.respond("gh", ["api"], json.dumps({"artifacts": [{"name": "apk-debug", "expired": False}]}))
    env.respond("gh", ["run", "download"])
    # `gh run download ... -D <dir>`: the fake can't see the temp dir, so drop the APK where -D points
    fake_gh = env.bin / "gh"
    fake_gh.write_text(fake_gh.read_text().replace(
        "sys.stdout.write(best", "if argv[:2] == ['run', 'download']:\n"
        "    Path(argv[argv.index('-D') + 1], 'app-debug.apk').write_bytes(b'APK')\n"
        "sys.stdout.write(best"))
    p = subprocess.run([sys.executable, str(SCRIPTS / "mercury_ci.py"), "--apply"], capture_output=True, text=True,
                       env=env.environ(MERCURY_BRIDGE_URL=url))
    assert "ready: demo #42 PR #9 with APK" in p.stdout, p.stdout + p.stderr
    st = env.task_state("t_abc")
    assert st["phase"] == "ready" and Path(st["apk"]).read_bytes() == b"APK"
    assert got[0]["body"]["kind"] == "ready" and got[0]["body"]["apk"] == st["apk"]


# -- mercury_resources.py --------------------------------------------------------------------
def _proc(root: Path, pid: int, ppid: int, argv: list[str], rss_pages: int = 100, start: int = 100):
    d = root / str(pid)
    d.mkdir(parents=True)
    (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
    fields = ["S", str(ppid)] + ["0"] * 17 + [str(start), "0", str(rss_pages)] + ["0"] * 20
    (d / "stat").write_text(f"{pid} (x) " + " ".join(fields))


@pytest.fixture
def fake_proc(tmp_path):
    root = tmp_path / "proc"
    root.mkdir()
    (root / "uptime").write_text("1000.0 1.0\n")
    _proc(root, 10, 1, ["/venv/bin/python", "-m", "hermes_cli.main", "gateway", "run"])
    _proc(root, 11, 1, ["/usr/bin/python3", "/repo/server/bridge.py"])
    _proc(root, 12, 1, ["/home/h/.local/bin/agy", "remote-control", "serve"])
    _proc(root, 13, 1, ["/home/h/.local/bin/claude", "rc"])                    # interactive
    _proc(root, 14, 1, ["/x/claude.exe", "--print", "--sdk-url", "wss://x"])  # headless, not ours
    _proc(root, 20, 10, ["python3", "/h/.hermes/scripts/code_task.py", "--agent", "claude"])
    _proc(root, 21, 20, ["/x/claude", "-p", "brief"], start=500)              # ours, older
    _proc(root, 22, 20, ["/x/claude", "-p", "brief"], start=900)              # ours, newest
    return root


def _meminfo(root, mb):
    (root / "meminfo").write_text(f"MemTotal: 16000000 kB\nMemAvailable: {mb * 1024} kB\n")


def test_enforce_stops_only_our_newest_coder(fake_proc, monkeypatch):
    import mercury_resources as mr
    monkeypatch.setattr(mr, "PROC", fake_proc)
    killed = []
    monkeypatch.setattr(mr.os, "kill", lambda pid, sig: killed.append(pid))
    _meminfo(fake_proc, 900)
    mr.cmd_enforce(type("A", (), {"floor_mb": 1536, "dry_run": False})())
    assert killed == [22]
    kinds = {p["pid"]: p["kind"] for p in mr.processes()}
    assert kinds[10] == "gateway" and kinds[11] == "bridge" and kinds[12] == "interactive"
    assert kinds[13] == "interactive"
    assert "ownedBy" not in {p["pid"]: p for p in mr.processes()}[14]


def test_enforce_does_nothing_above_the_floor(fake_proc, monkeypatch, capsys):
    import mercury_resources as mr
    monkeypatch.setattr(mr, "PROC", fake_proc)
    killed = []
    monkeypatch.setattr(mr.os, "kill", lambda pid, sig: killed.append(pid))
    _meminfo(fake_proc, 4000)
    mr.cmd_enforce(type("A", (), {"floor_mb": 1536, "dry_run": False})())
    assert killed == [] and capsys.readouterr().out == ""


# -- install.sh ---------------------------------------------------------------------------
FAKE_CRON = r'''
if argv[:2] == ["cron", "create"] and "/" not in argv[argv.index("--script") + 1]:
    with open(d / "cron_jobs", "a") as fh:
        fh.write("  Name:      " + argv[argv.index("--name") + 1] + "\n")
if argv[:2] == ["cron", "list"]:
    sys.stdout.write((d / "cron_jobs").read_text() if (d / "cron_jobs").exists() else "")
    sys.exit(0)
'''


def _real_cron(env):
    """Like hermes: a create with an absolute --script is refused but still exits 0."""
    fake = env.bin / "hermes"
    fake.write_text(fake.read_text().replace("best = None\n", FAKE_CRON + "best = None\n", 1))


def test_install_fails_loudly_when_a_cron_job_is_refused(env):
    fake = env.bin / "hermes"
    fake.write_text(fake.read_text().replace("best = None\n", "if argv[:2] == ['cron', 'list']:\n    sys.exit(0)\n"
                                             "best = None\n", 1))
    p = subprocess.run(["bash", str(SCRIPTS.parent / "install.sh")], capture_output=True, text=True,
                       env=env.environ(), timeout=60)
    assert p.returncode != 0 and "was not created" in p.stderr


def test_install_is_idempotent_and_bakes_in_absolute_paths(env):
    _real_cron(env)
    install = SCRIPTS.parent / "install.sh"
    run = lambda: subprocess.run(["bash", str(install)], capture_output=True, text=True,  # noqa: E731
                                 env=env.environ(), timeout=60)
    first = run()
    assert first.returncode == 0, first.stdout + first.stderr
    bin_dir = env.root / "mercury" / "bin"
    assert (bin_dir / "mercury_ship.py").exists() and os.access(env.root / "mercury" / "hooks" / "pre-push", os.X_OK)
    skill = (env.root / "skills" / "mercury" / "ship-issue" / "SKILL.md").read_text()
    assert "@BIN@" not in skill and f"B={bin_dir}" in skill
    key = env.root / "mercury" / "notify.key"
    assert oct(key.stat().st_mode)[-3:] == "600" and len(key.read_text().strip()) >= 32
    creates = env.called("hermes", "cron", "create")
    assert sorted(c["argv"][c["argv"].index("--name") + 1] for c in creates) == \
        ["mercury-ci", "mercury-intake", "mercury-resources"]
    assert all("--no-agent" in c["argv"] for c in creates)
    # hermes only accepts a bare filename under ~/.hermes/scripts
    assert all("/" not in c["argv"][c["argv"].index("--script") + 1] for c in creates)
    assert env.called("hermes", "config", "set", "kanban.max_in_progress", "2")
    # second run: the key is kept, and jobs that exist are not created twice
    before = key.read_text()
    assert run().returncode == 0
    assert key.read_text() == before
    assert len(env.called("hermes", "cron", "create")) == 3


def test_link_repoints_a_project_whose_primary_moved(env, repo):
    _gh_repo_view(env)
    _installed_skills(env)
    git(repo["main"], "remote", "set-url", "origin", "git@github.com:Flexingg/demo.git", env=repo["env"])
    (env.root / "profiles" / "dev-demo").mkdir(parents=True)
    (env.root / "profiles" / "dev-demo" / "config.yaml").write_text("{}")
    env.respond("hermes", ["kanban", "boards", "list"], "  demo   Demo\n")
    env.respond("hermes", ["project", "show"], "demo  [p_1]\n  board:   demo\n  primary: /tmp/old/demo\n")
    rc, out = env.run("mercury_project.py", "link", "Flexingg/demo")
    assert rc == 0, out
    assert env.called("hermes", "project", "add-folder", "demo", str(repo["main"]), "--primary")


def test_hermes_always_runs_as_the_default_profile(env):
    """The Plan agent files issues with HERMES_HOME=profiles/dev-x; projects are per
    profile, so kanban must still see the default profile's project (live finding)."""
    env.project()
    _issue_fakes(env)
    rc, out = env.run("mercury_issue.py", "file", "--project", "demo", "--draft", "-", stdin=json.dumps(DRAFT),
                      HERMES_HOME=str(env.root / "profiles" / "dev-demo"))
    assert rc == 0, out
    homes = {c["hermes_home"] for c in env.calls("hermes")}
    assert homes == {str(env.root)}


def test_link_sets_the_board_workdir(env, repo):
    _gh_repo_view(env)
    _installed_skills(env)
    git(repo["main"], "remote", "set-url", "origin", "git@github.com:Flexingg/demo.git", env=repo["env"])
    (env.root / "profiles" / "dev-demo").mkdir(parents=True)
    (env.root / "profiles" / "dev-demo" / "config.yaml").write_text("{}")
    env.respond("hermes", ["project", "show"], rc=1)
    assert env.run("mercury_project.py", "link", "Flexingg/demo")[0] == 0
    assert env.called("hermes", "kanban", "boards", "set-default-workdir", "demo", str(repo["main"]))


def test_publish_keeps_the_apk_the_gates_built_during_this_task(env, shipped):
    wt = shipped["wt"]
    apk_dir = wt / "app" / "build" / "outputs" / "apk" / "debug"
    apk_dir.mkdir(parents=True)
    (apk_dir / "app-debug.apk").write_bytes(b"FRESH")
    (wt / "app.txt").write_text("v2\n")
    notes = env.tmp / "notes.md"
    notes.write_text("x")
    env.respond("gh", ["pr", "list"], "[]")
    env.respond("gh", ["pr", "create"], "https://github.com/Flexingg/demo/pull/9\n")
    rc, out = env.run("mercury_ship.py", "publish", "--project", "demo", "--task", "t_abc", "--worktree",
                      str(wt), "--title", "t", "--notes", str(notes))
    assert rc == 0, out
    st = env.task_state("t_abc")
    assert Path(out["testBuild"]).read_bytes() == b"FRESH"
    assert st["localApk"] == out["testBuild"] and st["localApkSha"] == st["headSha"]


def test_publish_ignores_an_apk_from_before_the_task(env, shipped):
    wt = shipped["wt"]
    apk = wt / "app" / "build" / "outputs" / "apk" / "debug" / "app-debug.apk"
    apk.parent.mkdir(parents=True)
    apk.write_bytes(b"STALE")
    os.utime(apk, (1_000_000, 1_000_000))  # long before prepare ran
    (wt / "app.txt").write_text("v2\n")
    notes = env.tmp / "notes.md"
    notes.write_text("x")
    env.respond("gh", ["pr", "list"], "[]")
    env.respond("gh", ["pr", "create"], "https://github.com/Flexingg/demo/pull/9\n")
    rc, out = env.run("mercury_ship.py", "publish", "--project", "demo", "--task", "t_abc", "--worktree",
                      str(wt), "--title", "t", "--notes", str(notes))
    assert rc == 0 and out["testBuild"] is None


@pytest.mark.parametrize("apk_sha,offered", [("sha1", True), ("older", False)])
def test_ready_offers_the_local_build_only_for_the_same_commit(env, bridge, apk_sha, offered):
    got, url = bridge
    local = env.tmp / "local.apk"
    local.write_bytes(b"LOCAL")
    _review_task(env, localApk=str(local), localApkSha=apk_sha)
    _pr_view(env, "sha1", "SUCCESS")
    env.respond("gh", ["run", "list"], "[]")  # CI built nothing for this PR
    p = subprocess.run([sys.executable, str(SCRIPTS / "mercury_ci.py"), "--apply"], capture_output=True, text=True,
                       env=env.environ(MERCURY_BRIDGE_URL=url))
    assert "ready: demo #42 PR #9" in p.stdout, p.stdout + p.stderr
    assert got[0]["body"]["apk"] == (str(local) if offered else None)


def test_prepare_carries_only_the_sdk_path_into_the_worktree(env, shipped):
    """local.properties is untracked, so a fresh worktree lacks it and Gradle can't
    find the SDK (lumen). Only the SDK line may cross over."""
    text = (shipped["wt"] / "local.properties").read_text()
    assert text == "sdk.dir=/opt/android-sdk\n"


def test_gates_find_per_user_toolchains(env, repo, coder):
    """flutter lives in ~/dev/flutter/bin, which a login shell doesn't put on PATH."""
    tool = env.home / "dev" / "flutter" / "bin"
    tool.mkdir(parents=True)
    (tool / "flutter").write_text("#!/bin/sh\necho flutter-ran\n")
    (tool / "flutter").chmod(0o755)
    env.project(gates="flutter")
    rc, out = env.run("mercury_code.py", "gates", "--project", "demo", "--worktree", str(repo["wt"]),
                      PATH="/usr/bin:/bin")
    assert rc == 0, out
    assert "flutter-ran" in out["gates"]["tail"]
