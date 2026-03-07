#!/usr/bin/env bash
set -euo pipefail

DEVTRACK_REPO="/home/sa/.local/share/dev-tracker"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

REPO="$TMPDIR/repo"
mkdir -p "$REPO/.devtrack/sessions/20260307-175131"
mkdir -p "$REPO/.devtrack/sessions/20260307-193325"
mkdir -p "$REPO/.devtrack/rollback"

cat > "$REPO/.devtrack/config.yaml" <<EOF
project:
  name: "repo"
  root: "$REPO"

commands:
  build: ""
  test: ""
  health: ""
EOF

cat > "$REPO/.devtrack/state.yaml" <<'EOF'
updated_at: "2026-03-08T06:50:29"
last_checkpoint: "20260307-175131"

current_focus:
  task: ""
  status: "idle"
  blocker: ""

active_tasks: []

decisions: []

known_risks: []
EOF

cat > "$REPO/.devtrack/timeline.yaml" <<'EOF'
events: []
EOF

cat > "$REPO/.devtrack/sessions/20260307-175131/session.yaml" <<'EOF'
session_id: "20260307-175131"
started_at: "2026-03-07T17:51:58"
ended_at: "2026-03-07T19:11:10"
status: "completed"
summary: "old completed summary"
files_at_start: 10
files_changed: 0
EOF

cat > "$REPO/.devtrack/sessions/20260307-193325/session.yaml" <<'EOF'
session_id: "20260307-193325"
started_at: "2026-03-07T19:41:38"
ended_at: "2026-03-08T05:50:52+08:00"
status: "interrupted"
summary: "new interrupted summary"
files_at_start: 10
files_changed: 0
EOF

cat > "$REPO/.devtrack/rollback/manifest.json" <<EOF
{"created_at":"2026-03-07T19:11:10","description":"valid rollback","workspace_root":"$REPO","services_to_restart":[],"local_files":[],"remote_files":[]}
EOF

out="$(
  cd "$REPO"
  "$DEVTRACK_REPO/scripts/devtrack-context.sh" --stdout-only
)"

echo "$out" | grep -q 'new interrupted summary'
echo "$out" | grep -q '状态: interrupted'
