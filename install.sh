#!/bin/sh
# agent-crew installer for macOS / Linux / Git Bash. Best effort: the PowerShell installer
# (install.ps1) is the tested one. Same idea and flags:
#
#   ./install.sh [--claude-home DIR] [--no-settings] [--update] [--uninstall]
#
# Needs: sh, sha256sum or shasum, and python3 (or python) for the settings.json merge.
# The hooks are PowerShell scripts, so they need PowerShell 7 (`pwsh`) on this machine;
# without it the hook entries are not added to settings.json.
#
# Files you edited are never overwritten: the new version is written as "<file>.new".

set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
CLAUDE_HOME="${HOME}/.claude"
NO_SETTINGS=0
UPDATE=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --claude-home|-ClaudeHome) CLAUDE_HOME=$2; shift ;;
    --no-settings|-NoSettings) NO_SETTINGS=1 ;;
    --update|-Update) UPDATE=1 ;;
    --uninstall|-Uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$CLAUDE_HOME"
CLAUDE_HOME=$(cd "$CLAUDE_HOME" && pwd)
CREW="$CLAUDE_HOME/agent-crew"
RECORD="$CREW/installed.json"
SETTINGS="$CLAUDE_HOME/settings.json"

PY=$(command -v python3 || command -v python || true)

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# ---- record: one "relative/path": "hash" per line (same layout the PowerShell installer writes)
TMP_REC=$(mktemp)
trap 'rm -f "$TMP_REC" "$TMP_REC.new"' EXIT
if [ -f "$RECORD" ]; then
  sed -n 's/^ *"\([^"]*\)": *"\([0-9a-f]\{64\}\)",\{0,1\} *$/\1 \2/p' "$RECORD" > "$TMP_REC"
fi
rec_get() { awk -v k="$1" '$1==k {print $2; exit}' "$TMP_REC"; }
rec_set() { awk -v k="$1" '$1!=k' "$TMP_REC" > "$TMP_REC.new"; printf '%s %s\n' "$1" "$2" >>"$TMP_REC.new"; mv "$TMP_REC.new" "$TMP_REC"; }
rec_del() { awk -v k="$1" '$1!=k' "$TMP_REC" > "$TMP_REC.new"; mv "$TMP_REC.new" "$TMP_REC"; }
rec_save() {
  mkdir -p "$CREW"
  {
    printf '{\n  "version": "%s",\n  "claudeHome": "%s",\n  "files": {\n' "$1" "$CLAUDE_HOME"
    sort "$TMP_REC" | awk 'NR>1{print prev ","} {prev="    \"" $1 "\": \"" $2 "\""} END{if (NR>0) print prev}'
    printf '  }\n}\n'
  } > "$RECORD"
}

hook_cmd() { printf 'pwsh -NoProfile -ExecutionPolicy Bypass -File "%s/hooks/%s.ps1"' "$CREW" "$1"; }

# ---- settings.json merge (python)
settings_edit() { # $1 = install | uninstall
  [ -n "$PY" ] || { echo "  python not found: settings.json not changed" >&2; return 0; }
  CREW_DIR="$CREW" SETTINGS_PATH="$SETTINGS" MODE="$1" "$PY" - <<'PYEOF'
import json, os, re, shutil, sys, time
crew, path, mode = os.environ["CREW_DIR"], os.environ["SETTINGS_PATH"], os.environ["MODE"]
plan = [("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit", "guard-paths"),
        ("PostToolUse", "Edit|Write|MultiEdit|NotebookEdit", "check-caps"),
        ("PreCompact", None, "pre-compact"), ("PostCompact", None, "post-compact"),
        ("SessionStart", None, "session-start")]
ours = re.compile(r"agent-crew[\\/]+hooks[\\/]")
def cmd(s): return 'pwsh -NoProfile -ExecutionPolicy Bypass -File "%s/hooks/%s.ps1"' % (crew, s)
try:
    data = json.load(open(path, encoding="utf-8")) if os.path.exists(path) and os.path.getsize(path) else {}
except ValueError as e:
    sys.exit("settings.json is not valid JSON, not touching it: %s" % e)
before = json.dumps(data, sort_keys=True)
hooks = data.get("hooks", {})
for event in list(hooks):
    kept = []
    for group in hooks[event]:
        inner = [h for h in group.get("hooks", []) if not ours.search(h.get("command", ""))]
        if inner:
            group["hooks"] = inner
            kept.append(group)
    if kept: hooks[event] = kept
    else: del hooks[event]
if mode == "install":
    for event, matcher, script in plan:
        group = {"hooks": [{"type": "command", "command": cmd(script)}]}
        if matcher: group = dict([("matcher", matcher)] + list(group.items()))
        hooks.setdefault(event, []).append(group)
if hooks: data["hooks"] = hooks
else: data.pop("hooks", None)
if json.dumps(data, sort_keys=True) == before:
    print("  settings.json: nothing to change"); sys.exit(0)
if os.path.exists(path):
    backup = path + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, backup); print("  settings.json updated (backup: %s)" % backup)
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PYEOF
}

# ---- uninstall
if [ "$UNINSTALL" = 1 ]; then
  echo "Uninstalling agent-crew from $CLAUDE_HOME"
  removed=0; kept=0
  while read -r key hash; do
    [ -n "$key" ] || continue
    f="$CLAUDE_HOME/$key"
    rm -f "$f.new"
    [ -f "$f" ] || continue
    if [ "$(sha "$f")" = "$hash" ]; then rm -f "$f"; removed=$((removed+1)); else echo "  kept (you edited it): $key"; kept=$((kept+1)); fi
    d=$(dirname "$f")
    while [ "$d" != "$CLAUDE_HOME" ] && rmdir "$d" 2>/dev/null; do d=$(dirname "$d"); done
  done < "$TMP_REC"
  rm -f "$RECORD"; rmdir "$CREW" 2>/dev/null || true
  [ "$NO_SETTINGS" = 1 ] || settings_edit uninstall
  echo "Done: $removed file(s) removed, $kept kept."
  exit 0
fi

# ---- install / update
VERSION=$(tr -d ' \r\n' < "$SRC/VERSION")
echo "Installing agent-crew $VERSION in $CLAUDE_HOME"
mkdir -p "$CREW"
PLAN=$(mktemp)
{
  for f in "$SRC"/agents/*.md; do printf '%s|agents/%s|render|always\n' "$f" "$(basename "$f")"; done
  (cd "$SRC/skills" && find . -type f | sed 's|^\./||') | while read -r r; do printf '%s|skills/%s|plain|always\n' "$SRC/skills/$r" "$r"; done
  for d in hooks scripts data templates catalog; do
    (cd "$SRC/$d" && find . -type f | sed 's|^\./||') | while read -r r; do printf '%s|agent-crew/%s/%s|plain|always\n' "$SRC/$d/$r" "$d" "$r"; done
  done
  printf '%s|agent-crew/docs/RULES.md|plain|always\n' "$SRC/docs/RULES.md"
  printf '%s|agent-crew/VERSION|plain|always\n' "$SRC/VERSION"
  printf '%s|team/USER.md|plain|missing\n' "$SRC/templates/USER.md"
} > "$PLAN"

new=0; same=0; updated=0; pending=0; dotnew=0
RENDERED=$(mktemp)
while IFS='|' read -r src key mode when; do
  dest="$CLAUDE_HOME/$key"
  if [ "$mode" = render ]; then
    # @@HOOK:name@@ -> hook command; single quotes doubled for YAML single-quoted strings
    cp "$src" "$RENDERED"
    for name in $(grep -o '@@HOOK:[a-z-]*@@' "$src" | sort -u | sed 's/@@HOOK:\(.*\)@@/\1/'); do
      c=$(hook_cmd "$name" | sed "s/'/''/g; s/[&|\\\\]/\\\\&/g")
      sed "s|@@HOOK:$name@@|$c|g" "$RENDERED" > "$RENDERED.2"; mv "$RENDERED.2" "$RENDERED"
    done
  else
    cp "$src" "$RENDERED"
  fi
  newhash=$(sha "$RENDERED")
  if [ ! -f "$dest" ]; then
    if [ "$when" = missing ] && [ -n "$(rec_get "$key")" ]; then continue; fi
    mkdir -p "$(dirname "$dest")"; cp "$RENDERED" "$dest"; rec_set "$key" "$newhash"; new=$((new+1)); continue
  fi
  [ "$when" = missing ] && continue
  cur=$(sha "$dest"); recorded=$(rec_get "$key")
  if [ "$cur" = "$newhash" ]; then rec_set "$key" "$newhash"; same=$((same+1)); rm -f "$dest.new"
  elif [ -n "$recorded" ] && [ "$cur" = "$recorded" ]; then
    if [ "$UPDATE" = 1 ]; then cp "$RENDERED" "$dest"; rec_set "$key" "$newhash"; updated=$((updated+1)); rm -f "$dest.new"
    else echo "  newer version available (run with --update): $key"; pending=$((pending+1)); fi
  else
    cp "$RENDERED" "$dest.new"; echo "  differs from your copy, new version written next to it: $key.new"; dotnew=$((dotnew+1))
  fi
done < "$PLAN"

if [ "$UPDATE" = 1 ]; then
  while read -r key hash; do
    [ -n "$key" ] || continue
    grep -q -F "|$key|" "$PLAN" && continue
    f="$CLAUDE_HOME/$key"
    if [ ! -f "$f" ]; then rec_del "$key"; continue; fi
    if [ "$(sha "$f")" = "$hash" ]; then rm -f "$f"; rec_del "$key"; echo "  removed (no longer in agent-crew): $key"
    else echo "  no longer in agent-crew but you edited it, kept: $key"; fi
  done < "$TMP_REC"
fi
rm -f "$PLAN" "$RENDERED"
rec_save "$VERSION"

if [ "$NO_SETTINGS" = 1 ]; then
  echo "  settings.json: skipped (--no-settings)"
elif ! command -v pwsh >/dev/null 2>&1; then
  echo "  settings.json: skipped, PowerShell 7 (pwsh) not found; the hooks are PowerShell scripts"
else
  settings_edit install
fi
echo "Done: $new new, $updated updated, $same unchanged, $pending update(s) pending, $dotnew .new file(s) written."
echo "Restart Claude Code so it picks up the hooks and agents."
