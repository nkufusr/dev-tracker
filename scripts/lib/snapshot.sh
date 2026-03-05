#!/bin/bash
# 快照核心逻辑：收集文件 + 计算 SHA256 + 备份

# 从 config.yaml 解析本地追踪路径
_snap_parse_local_paths() {
    grep -A 100 '^  local_paths:' "$DEVTRACK_CONFIG" | \
        tail -n +2 | grep -E '^\s+- ' | \
        sed -E 's/^\s+- "?([^"]*)"?$/\1/'
}

_snap_parse_ignore_paths() {
    grep -A 100 '^  ignore_paths:' "$DEVTRACK_CONFIG" | \
        tail -n +2 | grep -E '^\s+- ' | \
        sed -E 's/^\s+- "?([^"]*)"?$/\1/'
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

_snap_collect_local_files() {
    local tmpfile
    tmpfile="$(mktemp)"
    local ignore_args=""
    while IFS= read -r pattern; do
        [ -n "$pattern" ] && ignore_args="$ignore_args -not -path './$pattern' -not -path '*/$pattern'"
    done < <(_snap_parse_ignore_paths)
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        eval "find . -type f -path './$pattern' $ignore_args 2>/dev/null" >> "$tmpfile" || true
    done < <(_snap_parse_local_paths)
    sort -u "$tmpfile"
    rm -f "$tmpfile"
}

# snapshot_create <output_dir> <description>
snapshot_create() {
    local out_dir="$1"
    local desc="${2:-}"
    local project_root="$PWD"

    mkdir -p "$out_dir/originals/local"

    # 本地文件
    local local_files_json="[]"
    while IFS= read -r relpath; do
        [ -z "$relpath" ] && continue
        relpath="${relpath#./}"
        local fullpath="$project_root/$relpath"
        [ -f "$fullpath" ] || continue

        local backup_rel="originals/local/$relpath"
        mkdir -p "$out_dir/$(dirname "$backup_rel")"
        cp "$fullpath" "$out_dir/$backup_rel"

        local sha
        sha="$(dt_sha256 "$fullpath")"
        local_files_json="$(echo "$local_files_json" | jq --arg p "$fullpath" --arg br "$backup_rel" --arg sha "$sha" \
            '. + [{"path": $p, "backup_rel": $br, "backup_sha256": $sha}]')"
    done < <(_snap_collect_local_files)

    # 远程文件
    local remote_files_json="[]"
    local r_host r_user r_key
    r_host="$(_snap_get_remote_host)"
    r_user="$(_snap_get_remote_user)"
    r_key="$(_snap_get_remote_ssh_key)"

    if [ -n "$r_host" ]; then
        mkdir -p "$out_dir/originals/remote"
        local ssh_opts=""
        [ -n "$r_key" ] && ssh_opts="-i $r_key"

        while IFS= read -r rpath; do
            [ -z "$rpath" ] && continue
            local backup_rel="originals/remote${rpath}"
            mkdir -p "$out_dir/$(dirname "$backup_rel")"
            if scp $ssh_opts "${r_user}@${r_host}:${rpath}" "$out_dir/$backup_rel" 2>/dev/null; then
                local sha
                sha="$(dt_sha256 "$out_dir/$backup_rel")"
                remote_files_json="$(echo "$remote_files_json" | jq \
                    --arg p "$rpath" --arg br "$backup_rel" --arg sha "$sha" \
                    '. + [{"path": $p, "backup_rel": $br, "backup_sha256": $sha}]')"
            fi
        done < <(_snap_parse_remote_paths)
    fi

    # 服务列表
    local services_json="[]"
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        services_json="$(echo "$services_json" | jq --arg s "$svc" '. + [$s]')"
    done < <(_snap_get_remote_services)

    # 写 manifest.json
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

    # 复制 state.yaml
    [ -f "$DEVTRACK_STATE" ] && cp "$DEVTRACK_STATE" "$out_dir/state.yaml"
}
