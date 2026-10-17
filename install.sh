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


# ---- settings.json merge (python)
settings_edit() { # $1 = install | uninstall
  [ -n "$PY" ] || { echo "  python not found: settings.json not changed" >&2; return 0; }
  CREW_DIR="$CREW" SETTINGS_PATH="$SETTINGS" SRC_DIR="$SRC" MODE="$1" "$PY" - <<'PYEOF'
import json, os, re, shutil, sys, time
crew, path, mode = os.environ["CREW_DIR"], os.environ["SETTINGS_PATH"], os.environ["MODE"]
def load(path):
    try:
        with open(path, encoding="utf-8") as f: return json.load(f)
    except (OSError, ValueError): return None
# ram-guard Bash/PowerShell entries get an `if` filter from the `hook_if` globs of the shipped and the user
# ram-guard.json (same rules as Get-RamHookIfRules in hooks/crew-common.ps1); unconditional when needed.
globs, scan_all = [], False
for f in (os.path.join(os.environ["SRC_DIR"], "data", "ram-guard.json"), os.path.join(os.path.dirname(path), "team", "ram-guard.json")):
    doc = load(f)
    if not isinstance(doc, dict): continue
    if doc.get("scan_all_commands") is True: scan_all = True
    kinds = doc.get("kinds")
    if not isinstance(kinds, dict): continue
    for kind in kinds.values():
        if not isinstance(kind, dict) or kind.get("enabled") is False or not kind.get("patterns"): continue
        if not kind.get("hook_if"): scan_all = True
        for g in kind.get("hook_if") or []:
            if isinstance(g, str) and g.strip() and g.strip() not in globs: globs.append(g.strip())
plan = [("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit", "guard-paths", None),
        ("PreToolUse", "Agent|Task", "ram-guard", None)]
if scan_all: plan.append(("PreToolUse", "Bash|PowerShell", "ram-guard", None))
else:
    for tool in ("Bash", "PowerShell"):
        for g in globs: plan.append(("PreToolUse", tool, "ram-guard", "%s(%s)" % (tool, g)))
plan += [("PostToolUse", "Edit|Write|MultiEdit|NotebookEdit", "check-caps", None),
         ("PreCompact", None, "pre-compact", None), ("PostCompact", None, "post-compact", None),
         ("SessionStart", None, "session-start", None)]
def cmd(s): return 'pwsh -NoProfile -ExecutionPolicy Bypass -File "%s/hooks/%s.ps1"' % (crew, s)
ours_cmds = set(cmd(p[2]) for p in plan)
class Ours:
    def search(self, c): return c in ours_cmds
ours = Ours()
try:
    data = json.load(open(path, encoding="utf-8")) if os.path.exists(path) and os.path.getsize(path) else {}
except ValueError as e:
    sys.exit("settings.json is not valid JSON, not touching it: %s" % e)
if not isinstance(data, dict): sys.exit("settings.json must contain a JSON object")
if mode == "check": sys.exit(0)
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
    for event, matcher, script, cond in plan:
        group = {"hooks": [{"type": "command", "command": cmd(script)}]}
        if cond: group["hooks"][0]["if"] = cond
        if matcher: group = dict([("matcher", matcher)] + list(group.items()))
        hooks.setdefault(event, []).append(group)
if hooks: data["hooks"] = hooks
else: data.pop("hooks", None)
if json.dumps(data, sort_keys=True) == before:
    print("  settings.json: nothing to change"); sys.exit(0)
if os.path.exists(path):
    backup = path + ".bak-" + time.strftime("%Y%m%d-%H%M%S") + "-%03d" % (int(time.time() * 1000) % 1000)
    shutil.copy2(path, backup); print("  settings.json updated (backup: %s)" % backup)
    for old in sorted(f for f in os.listdir(os.path.dirname(path)) if f.startswith("settings.json.bak-"))[:-3]:
        os.remove(os.path.join(os.path.dirname(path), old))
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PYEOF
}

# ---- validate settings.json FIRST: nothing is changed unless it parses
if [ "$NO_SETTINGS" != 1 ] && [ -f "$SETTINGS" ] && [ -n "$PY" ]; then
  settings_edit check || { echo "Nothing was changed. Fix or remove settings.json, or use --no-settings." >&2; exit 1; }
fi

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
    while [ "$d" != "$CLAUDE_HOME" ] && [ "$d" != "$CLAUDE_HOME/agents" ] && [ "$d" != "$CLAUDE_HOME/skills" ] && [ "$d" != "$CLAUDE_HOME/team" ] && rmdir "$d" 2>/dev/null; do d=$(dirname "$d"); done
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
  for f in "$SRC"/agents/*.md; do printf '%s|agents/%s|plain|always\n' "$f" "$(basename "$f")"; done
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
  cp "$src" "$RENDERED"
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
