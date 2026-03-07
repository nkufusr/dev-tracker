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

mkdir -p "$REPO/.worktrees/feature/src"
mkdir -p "$REPO/.worktrees/feature/build.Lakka-H5.aarch64/out"
mkdir -p "$REPO/.worktrees/feature/target/tmp"
mkdir -p "$REPO/.worktrees/feature/sources/cache"

printf 'keep\n' > "$REPO/.worktrees/feature/src/keep.txt"
printf 'drop build\n' > "$REPO/.worktrees/feature/build.Lakka-H5.aarch64/out/drop.txt"
printf 'drop target\n' > "$REPO/.worktrees/feature/target/tmp/drop.txt"
printf 'drop sources\n' > "$REPO/.worktrees/feature/sources/cache/drop.txt"

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
    - "build.Lakka-H5.aarch64/"
    - "target/"
    - "sources/"
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
with open(baseline) as fh:
    data = json.load(fh)
paths = {item["path"] for item in data["local_files"]}
keep = f"{root}/.worktrees/feature/src/keep.txt"
bad = {
    f"{root}/.worktrees/feature/build.Lakka-H5.aarch64/out/drop.txt",
    f"{root}/.worktrees/feature/target/tmp/drop.txt",
    f"{root}/.worktrees/feature/sources/cache/drop.txt",
}
if keep not in paths:
    raise SystemExit(f"missing kept worktree source: {keep}")
unexpected = sorted(path for path in bad if path in paths)
if unexpected:
    raise SystemExit("generated paths should be excluded: " + ", ".join(unexpected))
PY
)
