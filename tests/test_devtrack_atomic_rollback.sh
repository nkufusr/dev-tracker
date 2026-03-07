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

  mkdir -p .devtrack/rollback/originals/local
  printf 'sentinel\n' > .devtrack/rollback/SENTINEL
  cat > .devtrack/rollback/manifest.json <<EOF
{"created_at":"2026-03-08T00:00:00","description":"valid rollback","workspace_root":"$REPO","services_to_restart":[],"local_files":[],"remote_files":[]}
EOF

  "$DEVTRACK_REPO/scripts/devtrack-start.sh" >/dev/null
  printf 'changed\n' >> src/file.txt

  helper="$TMPDIR/bin"
  mkdir -p "$helper"
  cat > "$helper/cp" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    .devtrack/rollback*|.devtrack/rollback.*|*/.devtrack/rollback*|*/.devtrack/rollback.*)
      echo "forced cp failure for rollback target" >&2
      exit 99
      ;;
  esac
done
exec /bin/cp "$@"
EOF
  chmod +x "$helper/cp"

  if PATH="$helper:$PATH" "$DEVTRACK_REPO/scripts/devtrack-end.sh" "forced failure" >/dev/null 2>&1; then
    echo "expected devtrack-end.sh to fail" >&2
    exit 1
  fi

  test ! -f .devtrack/.active_session
  test -f .devtrack/rollback/manifest.json
  test -f .devtrack/rollback/SENTINEL
)
