#!/bin/bash
# devtrack checkpoint: Create a named checkpoint snapshot
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 检查点 <标签> [选项]

创建包含所有已追踪本地和远程文件备份的检查点。

参数:
  标签                     简短描述性标签（如 "auth-fix"、"v2-release"）

选项:
  --description <文本>     检查点的详细描述
  --skip-remote            跳过远程文件备份（仅本地）
  --dry-run                预览将捕获的内容，不实际创建检查点
  -h, --help               显示帮助
EOF
}

label=""
description=""
skip_remote=0
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        --description)    description="$2"; shift 2 ;;
        --skip-remote)    skip_remote=1; shift ;;
        --dry-run)        dry_run=1; shift ;;
        -*)               echo "未知选项: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [ -z "$label" ]; then
                label="$1"; shift
            else
                echo "多余参数: $1" >&2; usage >&2; exit 1
            fi
            ;;
    esac
done

[ -n "$label" ] || { echo "错误: 需要提供标签" >&2; usage >&2; exit 1; }

dt_require_init
dt_require_jq

TIMESTAMP="$(dt_timestamp)"
CP_NAME="${TIMESTAMP}-${label}"
CP_DIR="$DEVTRACK_CHECKPOINTS/$CP_NAME"

PROJECT_ROOT="$PWD"

# Parse config for tracked paths
parse_local_paths() {
    grep -A 100 '^  local_paths:' "$DEVTRACK_CONFIG" | \
        tail -n +2 | \
        grep -E '^\s+- ' | \
        sed -E 's/^\s+- "?([^"]*)"?$/\1/' | \
        while IFS= read -r pattern; do
            echo "$pattern"
        done
}

parse_ignore_paths() {
    grep -A 100 '^  ignore_paths:' "$DEVTRACK_CONFIG" | \
        tail -n +2 | \
        grep -E '^\s+- ' | \
        sed -E 's/^\s+- "?([^"]*)"?$/\1/' | \
        while IFS= read -r pattern; do
            echo "$pattern"
        done
}

parse_remote_paths() {
    local in_remote=0
    local in_paths=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^remote:'; then
            in_remote=1; continue
        fi
        if [ "$in_remote" -eq 1 ]; then
            if echo "$line" | grep -qE '^[a-z]'; then
                in_remote=0; in_paths=0; continue
            fi
            if echo "$line" | grep -qE '^\s+paths:'; then
                in_paths=1; continue
            fi
            if [ "$in_paths" -eq 1 ]; then
                if echo "$line" | grep -qE '^\s+[a-z]'; then
                    in_paths=0; continue
                fi
                echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/'
            fi
        fi
    done < "$DEVTRACK_CONFIG"
}

get_remote_host() {
    dt_yaml_get "$DEVTRACK_CONFIG" "" | true
    grep -A 5 '^remote:' "$DEVTRACK_CONFIG" 2>/dev/null | grep 'host:' | head -1 | sed -E 's/.*host:\s*"?([^"]*)"?.*/\1/' || true
}

get_remote_user() {
    grep -A 5 '^remote:' "$DEVTRACK_CONFIG" 2>/dev/null | grep 'user:' | head -1 | sed -E 's/.*user:\s*"?([^"]*)"?.*/\1/' || true
}

get_remote_ssh_key() {
    grep -A 5 '^remote:' "$DEVTRACK_CONFIG" 2>/dev/null | grep 'ssh_key:' | head -1 | sed -E 's/.*ssh_key:\s*"?([^"]*)"?.*/\1/' || true
}

get_remote_services() {
    local in_remote=0
    local in_services=0
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^remote:'; then
            in_remote=1; continue
        fi
        if [ "$in_remote" -eq 1 ]; then
            if echo "$line" | grep -qE '^[a-z]'; then
                in_remote=0; in_services=0; continue
            fi
            if echo "$line" | grep -qE '^\s+services:'; then
                in_services=1; continue
            fi
            if [ "$in_services" -eq 1 ]; then
                if echo "$line" | grep -qE '^\s+[a-z]'; then
                    in_services=0; continue
                fi
                echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/'
            fi
        fi
    done < "$DEVTRACK_CONFIG"
}

get_command() {
    local cmd_name="$1"
    grep -A 10 '^commands:' "$DEVTRACK_CONFIG" 2>/dev/null | grep "${cmd_name}:" | head -1 | sed -E "s/.*${cmd_name}:\s*\"?([^\"]*?)\"?\s*$/\1/" || true
}

# Collect local files matching tracked patterns
collect_local_files() {
    local tmpfile
    tmpfile="$(mktemp)"

    local ignore_args=""
    while IFS= read -r pattern; do
        [ -n "$pattern" ] && ignore_args="$ignore_args -not -path './$pattern' -not -path '*/$pattern'"
    done < <(parse_ignore_paths)

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        eval "find . -type f -path './$pattern' $ignore_args 2>/dev/null" >> "$tmpfile" || true
    done < <(parse_local_paths)

    sort -u "$tmpfile"
    rm -f "$tmpfile"
}

# Main logic
dt_info "正在创建检查点: $CP_NAME"

if [ "$dry_run" -eq 1 ]; then
    dt_info "[预演] 将在此处创建检查点: $DEVTRACK_CHECKPOINTS/$CP_NAME/"
    dt_info ""
    dt_info "将捕获的本地文件:"
    collect_local_files | while IFS= read -r f; do
        echo "  $f"
    done

    if [ "$skip_remote" -eq 0 ]; then
        r_host="$(get_remote_host)"
        if [ -n "$r_host" ]; then
            dt_info ""
            dt_info "将捕获的远程文件 ($r_host):"
            parse_remote_paths | while IFS= read -r rp; do
                echo "  $rp"
            done
        fi
    fi
    exit 0
fi

# Create checkpoint directory
mkdir -p "$CP_DIR/originals/local"

# Backup local files
local_files_json="[]"
while IFS= read -r relpath; do
    [ -z "$relpath" ] && continue
    relpath="${relpath#./}"
    fullpath="$PROJECT_ROOT/$relpath"
    [ -f "$fullpath" ] || continue

    backup_rel="originals/local/$relpath"
    backup_dir="$CP_DIR/$(dirname "$backup_rel")"
    mkdir -p "$backup_dir"
    cp "$fullpath" "$CP_DIR/$backup_rel"

    sha="$(dt_sha256 "$fullpath")"
    local_files_json="$(echo "$local_files_json" | jq --arg p "$fullpath" --arg br "$backup_rel" --arg sha "$sha" \
        '. + [{"path": $p, "backup_rel": $br, "backup_sha256": $sha, "current_sha256": $sha}]')"
done < <(collect_local_files)

local_count="$(echo "$local_files_json" | jq 'length')"
dt_info "已捕获 $local_count 个本地文件"

# Backup remote files
remote_files_json="[]"
if [ "$skip_remote" -eq 0 ]; then
    r_host="$(get_remote_host)"
    r_user="$(get_remote_user)"
    r_key="$(get_remote_ssh_key)"

    if [ -n "$r_host" ]; then
        mkdir -p "$CP_DIR/originals/remote"
        ssh_opts=""
        [ -n "$r_key" ] && ssh_opts="-i $r_key"

        while IFS= read -r rpath; do
            [ -z "$rpath" ] && continue
            backup_rel="originals/remote${rpath}"
            backup_dir="$CP_DIR/$(dirname "$backup_rel")"
            mkdir -p "$backup_dir"

            if scp $ssh_opts "${r_user}@${r_host}:${rpath}" "$CP_DIR/$backup_rel" 2>/dev/null; then
                sha="$(dt_sha256 "$CP_DIR/$backup_rel")"

                svc=""
                while IFS= read -r s; do
                    [ -z "$s" ] && continue
                    svc="$s"
                    break
                done < <(get_remote_services)

                remote_files_json="$(echo "$remote_files_json" | jq \
                    --arg p "$rpath" --arg br "$backup_rel" --arg sha "$sha" --arg svc "$svc" \
                    '. + [{"path": $p, "backup_rel": $br, "backup_sha256": $sha, "current_sha256": $sha, "service": $svc}]')"
                dt_info "  远程: $rpath"
            else
                dt_warn "远程文件备份失败: $rpath"
            fi
        done < <(parse_remote_paths)

        remote_count="$(echo "$remote_files_json" | jq 'length')"
        dt_info "已捕获 $remote_count 个远程文件"
    fi
fi

# Build manifest.json
services_json="[]"
while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    services_json="$(echo "$services_json" | jq --arg s "$svc" '. + [$s]')"
done < <(get_remote_services)

r_host="$(get_remote_host)"
r_user="$(get_remote_user)"
r_key="$(get_remote_ssh_key)"
build_cmd="$(get_command build)"
test_cmd="$(get_command test)"
health_cmd="$(get_command health)"

jq -n \
    --arg pv "2" \
    --arg ts "$(dt_iso_timestamp)" \
    --arg topic "$label" \
    --arg desc "$description" \
    --arg root "$PROJECT_ROOT" \
    --arg rhost "$r_host" \
    --arg ruser "$r_user" \
    --arg rkey "$r_key" \
    --arg build "$build_cmd" \
    --arg test "$test_cmd" \
    --arg health "$health_cmd" \
    --argjson services "$services_json" \
    --argjson local_files "$local_files_json" \
    --argjson remote_files "$remote_files_json" \
    '{
        package_version: ($pv | tonumber),
        created_at: $ts,
        topic: $topic,
        description: $desc,
        workspace_root: $root,
        server: {host: $rhost, user: $ruser, ssh_key_default: $rkey},
        commands: {build: $build, test: $test, health: $health},
        services_to_restart: $services,
        local_files: $local_files,
        remote_files: $remote_files
    }' > "$CP_DIR/manifest.json"

dt_info "已创建 manifest.json"

# Copy state.yaml snapshot
if [ -f "$DEVTRACK_STATE" ]; then
    cp "$DEVTRACK_STATE" "$CP_DIR/state.yaml"
    dt_info "已捕获 state.yaml 快照"
fi

# Generate rollback.sh
cat > "$CP_DIR/rollback.sh" << 'ROLLBACK_HEADER'
#!/bin/bash
# Auto-generated rollback script
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) echo "Usage: rollback.sh [--dry-run|--apply]"; exit 1 ;;
esac

echo "=== 回滚: $MODE ==="

WORKSPACE_ROOT="$(jq -r '.workspace_root' "$MANIFEST")"
REMOTE_HOST="$(jq -r '.server.host' "$MANIFEST")"
REMOTE_USER="$(jq -r '.server.user' "$MANIFEST")"
SSH_KEY="$(jq -r '.server.ssh_key_default' "$MANIFEST")"

SSH_OPTS=""
[ "$SSH_KEY" != "null" ] && [ -n "$SSH_KEY" ] && SSH_OPTS="-i $SSH_KEY"

echo ""
echo "--- 本地文件 ---"
jq -r '.local_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r backup_rel target; do
    src="$SCRIPT_DIR/$backup_rel"
    if [ ! -f "$src" ]; then
        echo "  跳过（备份缺失）: $target"
        continue
    fi
    if [ "$MODE" = "dry-run" ]; then
        echo "  将恢复: $target"
    else
        mkdir -p "$(dirname "$target")"
        cp "$src" "$target"
        echo "  已恢复: $target"
    fi
done

if [ "$REMOTE_HOST" != "null" ] && [ -n "$REMOTE_HOST" ]; then
    echo ""
    echo "--- 远程文件 ($REMOTE_HOST) ---"
    jq -r '.remote_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r backup_rel target; do
        src="$SCRIPT_DIR/$backup_rel"
        if [ ! -f "$src" ]; then
            echo "  跳过（备份缺失）: $target"
            continue
        fi
        if [ "$MODE" = "dry-run" ]; then
            echo "  将恢复: $REMOTE_HOST:$target"
        else
            scp $SSH_OPTS "$src" "${REMOTE_USER}@${REMOTE_HOST}:${target}" && \
                echo "  已恢复: $target" || \
                echo "  失败: $target"
        fi
    done

    echo ""
    echo "--- 服务 ---"
    if [ "$MODE" = "apply" ]; then
        jq -r '.services_to_restart[]' "$MANIFEST" 2>/dev/null | while read -r svc; do
            echo "  正在重启: $svc"
            ssh $SSH_OPTS "${REMOTE_USER}@${REMOTE_HOST}" "sudo systemctl restart $svc" && \
                echo "  已重启: $svc" || \
                echo "  重启失败: $svc"
        done
    else
        jq -r '.services_to_restart[]' "$MANIFEST" 2>/dev/null | while read -r svc; do
            echo "  将重启: $svc"
        done
    fi
fi

echo ""
echo "=== 回滚 $MODE 完成 ==="
ROLLBACK_HEADER

chmod +x "$CP_DIR/rollback.sh"
dt_info "已生成 rollback.sh"

# Generate verify.sh
cat > "$CP_DIR/verify.sh" << 'VERIFY_HEADER'
#!/bin/bash
# Auto-generated verification script
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }

echo "=== 回滚后验证 ==="

WORKSPACE_ROOT="$(jq -r '.workspace_root' "$MANIFEST")"
errors=0

echo ""
echo "--- 本地文件完整性 ---"
jq -r '.local_files[] | "\(.path)|\(.backup_sha256)"' "$MANIFEST" | while IFS='|' read -r fpath expected_sha; do
    if [ ! -f "$fpath" ]; then
        echo "  缺失: $fpath"
        errors=$((errors + 1))
        continue
    fi
    actual_sha="$(sha256sum "$fpath" | awk '{print $1}')"
    if [ "$actual_sha" = "$expected_sha" ]; then
        echo "  通过: $fpath"
    else
        echo "  不匹配: $fpath (期望: ${expected_sha:0:12}... 实际: ${actual_sha:0:12}...)"
        errors=$((errors + 1))
    fi
done

BUILD_CMD="$(jq -r '.commands.build' "$MANIFEST")"
TEST_CMD="$(jq -r '.commands.test' "$MANIFEST")"
HEALTH_CMD="$(jq -r '.commands.health' "$MANIFEST")"

if [ -n "$BUILD_CMD" ] && [ "$BUILD_CMD" != "null" ]; then
    echo ""
    echo "--- 构建检查 ---"
    cd "$WORKSPACE_ROOT"
    if eval "$BUILD_CMD" > /dev/null 2>&1; then
        echo "  构建: 通过"
    else
        echo "  构建: 失败"
        errors=$((errors + 1))
    fi
fi

if [ -n "$TEST_CMD" ] && [ "$TEST_CMD" != "null" ]; then
    echo ""
    echo "--- 测试检查 ---"
    cd "$WORKSPACE_ROOT"
    if eval "$TEST_CMD" > /dev/null 2>&1; then
        echo "  测试: 通过"
    else
        echo "  测试: 失败"
        errors=$((errors + 1))
    fi
fi

if [ -n "$HEALTH_CMD" ] && [ "$HEALTH_CMD" != "null" ]; then
    echo ""
    echo "--- 健康检查 ---"
    result="$(eval "$HEALTH_CMD" 2>/dev/null || echo "失败")"
    echo "  健康: $result"
fi

echo ""
if [ "$errors" -gt 0 ]; then
    echo "=== 验证失败（$errors 个问题）==="
    exit 1
else
    echo "=== 验证通过 ==="
fi
VERIFY_HEADER

chmod +x "$CP_DIR/verify.sh"
dt_info "已生成 verify.sh"

# Generate summary.md
cat > "$CP_DIR/summary.md" << EOF
# 检查点: $label

**创建时间**: $(dt_iso_timestamp)
**ID**: $CP_NAME

## 描述

${description:-未提供描述。}

## 内容

- **本地文件**: $local_count
$(echo "$local_files_json" | jq -r '.[] | "  - " + .path' 2>/dev/null || true)

EOF

remote_count="$(echo "$remote_files_json" | jq 'length')"
if [ "$remote_count" -gt 0 ]; then
    cat >> "$CP_DIR/summary.md" << EOF
- **远程文件**: $remote_count (主机: $r_host)
$(echo "$remote_files_json" | jq -r '.[] | "  - " + .path' 2>/dev/null || true)

EOF
fi

cat >> "$CP_DIR/summary.md" << EOF
## 回滚

\`\`\`bash
# 预览将恢复的内容
$CP_DIR/rollback.sh --dry-run

# 执行恢复
$CP_DIR/rollback.sh --apply

# 回滚后验证
$CP_DIR/verify.sh
\`\`\`
EOF

dt_info "已生成 summary.md"

# Update state.yaml
dt_yaml_set "$DEVTRACK_STATE" "last_checkpoint" "$CP_NAME"
dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"

# Update timeline
dt_timeline_append "checkpoint" "创建检查点: $CP_NAME - ${description:-$label}"

dt_info ""
dt_info "检查点已创建: $CP_NAME"
dt_info "  位置: $CP_DIR/"
dt_info "  回滚: $CP_DIR/rollback.sh --dry-run"
