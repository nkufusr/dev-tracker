#!/bin/bash
# Shared helpers for dev-tracker scripts

DEVTRACK_DIR=".devtrack"
DEVTRACK_CONFIG="$DEVTRACK_DIR/config.yaml"
DEVTRACK_STATE="$DEVTRACK_DIR/state.yaml"
DEVTRACK_TIMELINE="$DEVTRACK_DIR/timeline.yaml"
DEVTRACK_CONTEXT="$DEVTRACK_DIR/context.md"
DEVTRACK_SESSIONS="$DEVTRACK_DIR/sessions"
DEVTRACK_CHECKPOINTS="$DEVTRACK_DIR/checkpoints"

dt_die() {
    echo "错误: $*" >&2
    exit 1
}

dt_warn() {
    echo "警告: $*" >&2
}

dt_info() {
    echo ":: $*"
}

dt_require_init() {
    [ -d "$DEVTRACK_DIR" ] || dt_die "未找到 .devtrack/ 目录。请先运行 'devtrack 初始化'"
    [ -f "$DEVTRACK_CONFIG" ] || dt_die "未找到 .devtrack/config.yaml。请先运行 'devtrack 初始化'"
}

dt_require_jq() {
    command -v jq >/dev/null 2>&1 || dt_die "需要 jq 但未安装。安装命令: sudo apt install jq"
}

dt_timestamp() {
    date '+%Y%m%d-%H%M%S'
}

dt_iso_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S'
}

dt_date_only() {
    date '+%Y-%m-%d'
}

# Simple YAML key: value reader (top-level only)
dt_yaml_get() {
    local file="$1" key="$2" default="${3:-}"
    [ -f "$file" ] || { printf "%s" "$default"; return 0; }
    local line value
    line="$(grep -E "^${key}:" "$file" | head -n 1 || true)"
    if [ -z "$line" ]; then
        printf "%s" "$default"
        return 0
    fi
    value="${line#${key}:}"
    value="$(printf "%s" "$value" | sed -E 's/^[[:space:]]+//; s/^"//; s/"$//')"
    printf "%s" "$value"
}

# Simple YAML key: value writer (top-level, in-place)
dt_yaml_set() {
    local file="$1" key="$2" value="$3"
    [ -f "$file" ] || dt_die "File not found: $file"
    local tmp
    tmp="$(mktemp)"
    if grep -qE "^${key}:" "$file"; then
        sed -E "s|^${key}:.*|${key}: \"${value}\"|" "$file" > "$tmp"
    else
        cp "$file" "$tmp"
        echo "${key}: \"${value}\"" >> "$tmp"
    fi
    mv -f "$tmp" "$file"
}

# Append an entry to timeline.yaml
dt_timeline_append() {
    local event_type="$1" description="$2"
    local ts
    ts="$(dt_iso_timestamp)"
    [ -f "$DEVTRACK_TIMELINE" ] || echo "events:" > "$DEVTRACK_TIMELINE"
    cat >> "$DEVTRACK_TIMELINE" << EOF
  - timestamp: "$ts"
    type: "$event_type"
    description: "$description"
EOF
}

# Compute SHA-256 of a file
dt_sha256() {
    local file="$1"
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
}

# List checkpoints (sorted by name, newest first)
dt_list_checkpoints() {
    if [ -d "$DEVTRACK_CHECKPOINTS" ]; then
        ls -1r "$DEVTRACK_CHECKPOINTS" 2>/dev/null
    fi
}

# Find a checkpoint by label (partial match)
dt_find_checkpoint() {
    local query="$1"
    local match
    match="$(dt_list_checkpoints | grep -F "$query" | head -1)"
    if [ -n "$match" ]; then
        echo "$match"
    fi
}
