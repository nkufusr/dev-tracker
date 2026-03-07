#!/usr/bin/env bash
set -euo pipefail

DEVTRACK_REPO="/home/sa/.local/share/dev-tracker"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

REPO="$TMPDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name "Test User"
git -C "$REPO" config user.email "test@example.com"
printf 'base\n' > "$REPO/base.txt"
git -C "$REPO" add base.txt
git -C "$REPO" commit -qm "init"
git -C "$REPO" worktree add "$REPO/.worktrees/feature" -b feature >/dev/null 2>&1
printf 'from-worktree\n' > "$REPO/.worktrees/feature/hello.txt"

(
  cd "$REPO"
  "$DEVTRACK_REPO/scripts/devtrack-init.sh" --force >/dev/null
  cat > .devtrack/config.yaml <<'EOF'
project:
  name: "repo"
  root: "__ROOT__"

tracking:
  local_paths:
    - "**/*.txt"
  ignore_paths:
    - ".git/"
    - ".worktrees/"
    - ".devtrack/"

commands:
  build: ""
  test: ""
  health: ""
EOF
  sed -i "s|__ROOT__|$REPO|" .devtrack/config.yaml
  "$DEVTRACK_REPO/scripts/devtrack-start.sh" >/dev/null
  session_id="$(cat .devtrack/.active_session)"
  python3 - "$REPO" ".devtrack/sessions/$session_id/baseline.json" <<'PY'
import json, sys
root, baseline = sys.argv[1], sys.argv[2]
target = f"{root}/.worktrees/feature/hello.txt"
with open(baseline) as fh:
    data = json.load(fh)
paths = {item["path"] for item in data["local_files"]}
if target not in paths:
    raise SystemExit(f"missing worktree file in baseline: {target}")
PY
)
