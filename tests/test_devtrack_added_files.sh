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
mkdir -p "$REPO/src"
printf 'before\n' > "$REPO/src/existing.txt"
git -C "$REPO" add src/existing.txt
git -C "$REPO" commit -qm "init"

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
    - ".devtrack/"

commands:
  build: ""
  test: ""
  health: ""
EOF
  sed -i "s|__ROOT__|$REPO|" .devtrack/config.yaml
  "$DEVTRACK_REPO/scripts/devtrack-start.sh" >/dev/null
  printf 'new\n' > src/added.txt
  "$DEVTRACK_REPO/scripts/devtrack-end.sh" "added-file smoke" >/dev/null

  latest="$(find .devtrack/sessions -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  grep -q '^status: "completed"$' "$latest/session.yaml"
  grep -q '^files_changed: 1$' "$latest/session.yaml"
  grep -q '## 新增文件 (1)' "$latest/changes.md"
  grep -q 'src/added.txt' "$latest/changes.md"
)
