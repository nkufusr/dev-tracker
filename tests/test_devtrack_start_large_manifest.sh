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

for d in $(seq 1 180); do
  mkdir -p "$REPO/pkg$d/src" "$REPO/pkg$d/docs"
  for f in $(seq 1 12); do
    printf 'int v_%s_%s = %s;\n' "$d" "$f" "$f" > "$REPO/pkg$d/src/file$f.c"
    printf '# doc %s %s\n' "$d" "$f" > "$REPO/pkg$d/docs/file$f.md"
  done
done

git -C "$REPO" add .
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
    - "scripts/*"
    - "**/*.c"
    - "**/*.md"
    - "**/Makefile"
    - "**/Config.in"
    - "**/package.mk"
    - "**/*.sh"
    - "**/*.yaml"
    - "**/*.yml"
    - "**/*.json"
  ignore_paths:
    - ".claude/"
    - ".git/"
    - ".devtrack/"

commands:
  build: ""
  test: ""
  health: ""
EOF
  sed -i "s|__ROOT__|$REPO|" .devtrack/config.yaml

  if ! timeout 8s "$DEVTRACK_REPO/scripts/devtrack-start.sh" >/dev/null; then
    echo "devtrack-start.sh should finish within 8 seconds on a medium-sized source tree" >&2
    exit 1
  fi

  session_id="$(cat .devtrack/.active_session)"
  baseline=".devtrack/sessions/$session_id/baseline.json"
  [ -f "$baseline" ]

  expected_files=$((180 * 12 * 2))
  actual_files="$(jq '.local_files | length' "$baseline")"
  [ "$actual_files" -eq "$expected_files" ]
)
