#!/bin/bash
# 全量快照：备份所有文件（排除 build 产物），生成 rollback.sh + verify.sh

_snap_parse_excludes() {
    local in_exclude=0
    while IFS= read -r line; do
        echo "$line" | grep -qE '^exclude:' && { in_exclude=1; continue; }
        if [ "$in_exclude" -eq 1 ]; then
            echo "$line" | grep -qE '^[a-z]' && break
            echo "$line" | grep -qE '^\s+- ' && \
                echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/'
        fi
    done < "$DEVTRACK_CONFIG"
}

_snap_parse_remote_paths() {
    local in_remote=0 in_paths=0
    while IFS= read -r line; do
        echo "$line" | grep -qE '^remote:' && { in_remote=1; continue; }
        if [ "$in_remote" -eq 1 ]; then
            echo "$line" | grep -qE '^[a-z]' && { in_remote=0; in_paths=0; continue; }
            echo "$line" | grep -qE '^\s+paths:' && { in_paths=1; continue; }
            [ "$in_paths" -eq 1 ] && {
                echo "$line" | grep -qE '^\s+[a-z]' && { in_paths=0; continue; }
                echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/'
            }
        fi
    done < "$DEVTRACK_CONFIG"
}

_snap_get_remote_host() {
    grep -A 5 '^remote:' "$DEVTRACK_CONFIG" 2>/dev/null | grep 'host:' | head -1 | sed -E 's/.*host:\s*"?([^"]*)"?.*/\1/' || true
}
_snap_get_remote_user() {
    grep -A 5 '^remote:' "$DEVTRACK_CONFIG" 2>/dev/null | grep 'user:' | head -1 | sed -E 's/.*user:\s*"?([^"]*)"?.*/\1/' || true
}
_snap_get_remote_ssh_key() {
    grep -A 5 '^remote:' "$DEVTRACK_CONFIG" 2>/dev/null | grep 'ssh_key:' | head -1 | sed -E 's/.*ssh_key:\s*"?([^"]*)"?.*/\1/' || true
}
_snap_get_remote_services() {
    local in_remote=0 in_services=0
    while IFS= read -r line; do
        echo "$line" | grep -qE '^remote:' && { in_remote=1; continue; }
        if [ "$in_remote" -eq 1 ]; then
            echo "$line" | grep -qE '^[a-z]' && { in_remote=0; in_services=0; continue; }
            echo "$line" | grep -qE '^\s+services:' && { in_services=1; continue; }
            [ "$in_services" -eq 1 ] && {
                echo "$line" | grep -qE '^\s+[a-z]' && { in_services=0; continue; }
                echo "$line" | sed -E 's/^\s+- "?([^"]*)"?$/\1/'
            }
        fi
    done < "$DEVTRACK_CONFIG"
}
_snap_get_command() {
    local cmd_name="$1"
    grep -A 10 '^commands:' "$DEVTRACK_CONFIG" 2>/dev/null | grep "${cmd_name}:" | head -1 | sed -E "s/.*${cmd_name}:\s*\"?([^\"]*?)\"?\s*$/\1/" || true
}

# 收集所有文件（全量，排除 build 产物）
_snap_collect_all_files() {
    local exclude_file
    exclude_file="$(mktemp)"

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        # 去掉尾部 / 和通配符前缀
        pattern="${pattern%/}"
        pattern="${pattern#\*/}"
        echo "$pattern" >> "$exclude_file"
    done < <(_snap_parse_excludes)

    find . -type f | while IFS= read -r filepath; do
        local skip=0
        while IFS= read -r excl; do
            case "$filepath" in
                */"$excl"/*|*/"$excl"|./"$excl"/*|./"$excl")
                    skip=1; break ;;
            esac
            # 通配符模式匹配（如 *.class）
            case "$excl" in
                \*.*)
                    ext="${excl#\*}"
                    case "$filepath" in
                        *"$ext") skip=1; break ;;
                    esac ;;
            esac
        done < "$exclude_file"
        [ "$skip" -eq 0 ] && echo "$filepath"
    done | sort

    rm -f "$exclude_file"
}

# snapshot_manifest_only <output_json> — 轻量：只记录文件路径和 SHA-256，不复制文件
snapshot_manifest_only() {
    local out_file="$1"
    local project_root="$PWD"
    local files_json="[]"

    while IFS= read -r relpath; do
        [ -z "$relpath" ] && continue
        relpath="${relpath#./}"
        fullpath="$project_root/$relpath"
        [ -f "$fullpath" ] || continue
        sha="$(dt_sha256 "$fullpath")"
        files_json="$(echo "$files_json" | jq --arg p "$fullpath" --arg sha "$sha" \
            '. + [{"path": $p, "sha256": $sha}]')"
    done < <(_snap_collect_all_files)

    jq -n --arg ts "$(dt_iso_timestamp)" --argjson files "$files_json" \
        '{created_at: $ts, local_files: $files}' > "$out_file"
}

# snapshot_create <output_dir> <description>
snapshot_create() {
    local out_dir="$1"
    local desc="${2:-}"
    local project_root="$PWD"

    mkdir -p "$out_dir/originals/local"

    # 全量备份本地文件
    local local_files_json="[]"
    local count=0
    while IFS= read -r relpath; do
        [ -z "$relpath" ] && continue
        relpath="${relpath#./}"
        fullpath="$project_root/$relpath"
        [ -f "$fullpath" ] || continue

        backup_rel="originals/local/$relpath"
        mkdir -p "$out_dir/$(dirname "$backup_rel")"
        cp "$fullpath" "$out_dir/$backup_rel"

        sha="$(dt_sha256 "$fullpath")"
        local_files_json="$(echo "$local_files_json" | jq --arg p "$fullpath" --arg br "$backup_rel" --arg sha "$sha" \
            '. + [{"path": $p, "backup_rel": $br, "backup_sha256": $sha}]')"
        count=$((count + 1))
    done < <(_snap_collect_all_files)

    # 远程文件
    local remote_files_json="[]"
    r_host="$(_snap_get_remote_host)"
    r_user="$(_snap_get_remote_user)"
    r_key="$(_snap_get_remote_ssh_key)"

    if [ -n "$r_host" ]; then
        mkdir -p "$out_dir/originals/remote"
        ssh_opts=""
        [ -n "$r_key" ] && ssh_opts="-i $r_key"

        while IFS= read -r rpath; do
            [ -z "$rpath" ] && continue
            backup_rel="originals/remote${rpath}"
            mkdir -p "$out_dir/$(dirname "$backup_rel")"
            if scp $ssh_opts "${r_user}@${r_host}:${rpath}" "$out_dir/$backup_rel" 2>/dev/null; then
                sha="$(dt_sha256 "$out_dir/$backup_rel")"
                remote_files_json="$(echo "$remote_files_json" | jq \
                    --arg p "$rpath" --arg br "$backup_rel" --arg sha "$sha" \
                    '. + [{"path": $p, "backup_rel": $br, "backup_sha256": $sha}]')"
            fi
        done < <(_snap_parse_remote_paths)
    fi

    # 服务列表
    services_json="[]"
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        services_json="$(echo "$services_json" | jq --arg s "$svc" '. + [$s]')"
    done < <(_snap_get_remote_services)

    # manifest.json
    jq -n \
        --arg ts "$(dt_iso_timestamp)" \
        --arg desc "$desc" \
        --arg root "$project_root" \
        --arg rhost "$r_host" \
        --arg ruser "$r_user" \
        --arg rkey "$r_key" \
        --arg build "$(_snap_get_command build)" \
        --arg test "$(_snap_get_command test)" \
        --arg health "$(_snap_get_command health)" \
        --argjson services "$services_json" \
        --argjson local_files "$local_files_json" \
        --argjson remote_files "$remote_files_json" \
        '{
            created_at: $ts,
            description: $desc,
            workspace_root: $root,
            server: {host: $rhost, user: $ruser, ssh_key_default: $rkey},
            commands: {build: $build, test: $test, health: $health},
            services_to_restart: $services,
            local_files: $local_files,
            remote_files: $remote_files
        }' > "$out_dir/manifest.json"

    # state.yaml 快照
    [ -f "$DEVTRACK_STATE" ] && cp "$DEVTRACK_STATE" "$out_dir/state.yaml"

    # 生成 rollback.sh
    cat > "$out_dir/rollback.sh" << 'ROLLBACK_EOF'
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.json"
command -v jq >/dev/null 2>&1 || { echo "错误: 需要 jq"; exit 1; }

MODE="${1:---dry-run}"
[ "$MODE" = "--apply" ] || MODE="--dry-run"

echo "=== 回滚 ($MODE) ==="
ROOT="$(jq -r '.workspace_root' "$MANIFEST")"
echo "项目: $ROOT"
echo ""

echo "--- 本地文件 ---"
jq -r '.local_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r brel target; do
    src="$SCRIPT_DIR/$brel"
    [ -f "$src" ] || { echo "  跳过(缺失): $target"; continue; }
    if [ "$MODE" = "--dry-run" ]; then
        if [ -f "$target" ]; then
            cur="$(sha256sum "$target" | awk '{print $1}')"
            bak="$(sha256sum "$src" | awk '{print $1}')"
            [ "$cur" = "$bak" ] && echo "  未变更: $(echo "$target" | sed "s|$ROOT/||")" || echo "  将恢复: $(echo "$target" | sed "s|$ROOT/||")"
        else
            echo "  将创建: $(echo "$target" | sed "s|$ROOT/||")"
        fi
    else
        mkdir -p "$(dirname "$target")"
        cp "$src" "$target"
        echo "  已恢复: $(echo "$target" | sed "s|$ROOT/||")"
    fi
done

RHOST="$(jq -r '.server.host // empty' "$MANIFEST")"
if [ -n "$RHOST" ]; then
    RUSER="$(jq -r '.server.user' "$MANIFEST")"
    RKEY="$(jq -r '.server.ssh_key_default // empty' "$MANIFEST")"
    SSH=""
    [ -n "$RKEY" ] && SSH="-i $RKEY"

    RC="$(jq '.remote_files | length' "$MANIFEST")"
    if [ "$RC" -gt 0 ]; then
        echo ""
        echo "--- 远程文件 ($RHOST) ---"
        jq -r '.remote_files[] | "\(.backup_rel)|\(.path)"' "$MANIFEST" | while IFS='|' read -r brel target; do
            src="$SCRIPT_DIR/$brel"
            [ -f "$src" ] || continue
            if [ "$MODE" = "--dry-run" ]; then
                echo "  将恢复: $RHOST:$target"
            else
                scp $SSH "$src" "${RUSER}@${RHOST}:${target}" 2>/dev/null && echo "  已恢复: $target" || echo "  失败: $target"
            fi
        done
        echo ""
        echo "--- 服务 ---"
        jq -r '.services_to_restart[]' "$MANIFEST" 2>/dev/null | while read -r svc; do
            [ -z "$svc" ] && continue
            if [ "$MODE" = "--dry-run" ]; then
                echo "  将重启: $svc"
            else
                ssh $SSH "${RUSER}@${RHOST}" "sudo systemctl restart $svc" 2>/dev/null && echo "  已重启: $svc" || echo "  重启失败: $svc"
            fi
        done
    fi
fi

echo ""
echo "=== 回滚 $MODE 完成 ==="
[ "$MODE" = "--dry-run" ] && echo "确认后执行: $0 --apply"
ROLLBACK_EOF
    chmod +x "$out_dir/rollback.sh"

    # 生成 verify.sh
    cat > "$out_dir/verify.sh" << 'VERIFY_EOF'
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.json"
command -v jq >/dev/null 2>&1 || { echo "错误: 需要 jq"; exit 1; }

ROOT="$(jq -r '.workspace_root' "$MANIFEST")"
echo "=== 回滚后验证 ==="
errors=0

echo ""
echo "--- 文件完整性 ---"
total=0; ok=0; mismatch=0; missing=0
jq -r '.local_files[] | "\(.path)|\(.backup_sha256)"' "$MANIFEST" | while IFS='|' read -r fpath expected; do
    total=$((total+1))
    if [ ! -f "$fpath" ]; then
        echo "  缺失: $(echo "$fpath" | sed "s|$ROOT/||")"
        missing=$((missing+1))
        continue
    fi
    actual="$(sha256sum "$fpath" | awk '{print $1}')"
    if [ "$actual" = "$expected" ]; then
        ok=$((ok+1))
    else
        echo "  不匹配: $(echo "$fpath" | sed "s|$ROOT/||")"
        mismatch=$((mismatch+1))
    fi
done
echo "  检查完成"

BUILD="$(jq -r '.commands.build // empty' "$MANIFEST")"
TEST="$(jq -r '.commands.test // empty' "$MANIFEST")"
HEALTH="$(jq -r '.commands.health // empty' "$MANIFEST")"

if [ -n "$BUILD" ]; then
    echo ""
    echo "--- 构建验证 ---"
    cd "$ROOT"
    if eval "$BUILD" > /dev/null 2>&1; then
        echo "  构建: 通过"
    else
        echo "  构建: 失败"
        errors=$((errors+1))
    fi
fi

if [ -n "$TEST" ]; then
    echo ""
    echo "--- 测试验证 ---"
    cd "$ROOT"
    if eval "$TEST" > /dev/null 2>&1; then
        echo "  测试: 通过"
    else
        echo "  测试: 失败"
        errors=$((errors+1))
    fi
fi

if [ -n "$HEALTH" ]; then
    echo ""
    echo "--- 健康检查 ---"
    result="$(eval "$HEALTH" 2>/dev/null || echo "失败")"
    echo "  健康: $result"
fi

echo ""
echo "=== 验证完成 ==="
VERIFY_EOF
    chmod +x "$out_dir/verify.sh"
}
