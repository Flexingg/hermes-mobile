#!/usr/bin/env bash
# Install Mercury's Hermes-side pieces into ~/.hermes. Idempotent: re-run after
# pulling changes. Copies (never symlinks into this repo), so switching branches
# here doesn't change what Hermes runs until you install again.
#
#   hermes/install.sh            install / update
#   hermes/install.sh --check    show what is installed, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
HERMES_ROOT="${MERCURY_HERMES_ROOT:-$REAL_HOME/.hermes}"
HERMES_BIN="${MERCURY_HERMES_BIN:-$REAL_HOME/.local/bin/hermes}"
MERCURY="$HERMES_ROOT/mercury"
BIN="$MERCURY/bin"
SKILLS="$HERMES_ROOT/skills/mercury"
CRON_SCRIPTS="$HERMES_ROOT/scripts"

if [ "${1:-}" = "--check" ]; then
  echo "scripts:  $(ls "$BIN" 2>/dev/null | tr '\n' ' ')"
  echo "skills:   $(ls "$SKILLS" 2>/dev/null | tr '\n' ' ')"
  echo "hook:     $([ -x "$MERCURY/hooks/pre-push" ] && echo installed || echo missing)"
  echo "notify:   $([ -s "$MERCURY/notify.key" ] && echo "key present" || echo "key missing")"
  echo "cron:     $("$HERMES_BIN" cron list 2>/dev/null | grep -oE 'mercury-[a-z]+' | sort -u | tr '\n' ' ')"
  exit 0
fi

umask 077
mkdir -p "$BIN" "$MERCURY/hooks" "$MERCURY/tasks" "$MERCURY/apks" "$SKILLS" "$CRON_SCRIPTS"

# 1. scripts (stdlib-only Python) and the per-worktree push guard
install -m 0755 "$HERE"/scripts/mercury_*.py "$BIN/"
install -m 0755 "$HERE/hooks/pre-push" "$MERCURY/hooks/pre-push"

# 2. skills, with the absolute script dir baked in (workers have a different HOME)
for dir in "$HERE"/skills/*/; do
  name="$(basename "$dir")"
  mkdir -p "$SKILLS/$name"
  sed "s#@BIN@#$BIN#g" "$dir/SKILL.md" > "$SKILLS/$name/SKILL.md.tmp"
  mv "$SKILLS/$name/SKILL.md.tmp" "$SKILLS/$name/SKILL.md"
done
chmod -R go-w "$SKILLS"

# 3. the key Hermes uses to reach the bridge's /internal/notify (the bridge reads it too)
if [ ! -s "$MERCURY/notify.key" ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$MERCURY/notify.key"
fi
chmod 600 "$MERCURY/notify.key"

# 4. at most two coding tasks at once on this box
"$HERMES_BIN" config set kanban.max_in_progress 2 >/dev/null

# 5. background jobs: script-only (--no-agent) cron under the default profile
cron_job() {  # name schedule command
  local name="$1" schedule="$2" cmd="$3" wrapper="$CRON_SCRIPTS/$1.sh"
  printf '#!/usr/bin/env bash\n# installed by hermes-mobile/hermes/install.sh\nexec %s\n' "$cmd" > "$wrapper"
  chmod 700 "$wrapper"
  if cron_has "$name"; then
    echo "cron $name: present"
    return
  fi
  # --script takes a filename relative to ~/.hermes/scripts. `hermes cron create`
  # exits 0 even when it refuses a job, so success is checked by listing, not rc.
  "$HERMES_BIN" cron create "$schedule" --name "$name" --no-agent --script "$(basename "$wrapper")" \
    --deliver local
  if ! cron_has "$name"; then
    echo "install.sh: cron job $name was not created (see the message above)" >&2
    exit 1
  fi
  echo "cron $name: created ($schedule)"
}
cron_has() { "$HERMES_BIN" cron list --all 2>/dev/null | grep -qE "Name: +$1\$"; }
cron_job mercury-intake    "*/2 * * * *" "python3 $BIN/mercury_intake.py --apply"
cron_job mercury-ci        "*/2 * * * *" "python3 $BIN/mercury_ci.py --apply"
cron_job mercury-resources "* * * * *"   "python3 $BIN/mercury_resources.py enforce"

echo "installed: $BIN, $SKILLS, $MERCURY/hooks/pre-push"
echo "next: link a repo, e.g. python3 $BIN/mercury_project.py link Flexingg/lumen-launcher --coder claude"
