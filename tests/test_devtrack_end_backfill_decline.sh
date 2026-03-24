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
printf 'before\n' > "$REPO/src/file.txt"
git -C "$REPO" add src/file.txt
git -C "$REPO" commit -qm "init"

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
"$DEVTRACK_REPO/scripts/devtrack-end.sh" "baseline" >/dev/null

printf 'after\n' >> src/file.txt

set +e
output="$(printf 'n\n' | "$DEVTRACK_REPO/scripts/devtrack-end.sh" "decline smoke" 2>&1)"
status=$?
set -e

test "$status" -ne 0
echo "$output" | grep -q "检测到没有活跃会话"
echo "$output" | grep -q "是否创建补录会话并继续结束"
echo "$output" | grep -q "已取消补录"

count="$(find .devtrack/sessions -mindepth 1 -maxdepth 1 -type d | wc -l)"
test "$count" -eq 1
test ! -f .devtrack/.active_session
