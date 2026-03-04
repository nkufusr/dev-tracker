#!/bin/bash
# devtrack session: 管理 AI 会话生命周期
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
用法: devtrack 会话 <开始|结束|列表> [选项]

管理 AI 开发会话。

子命令:
  开始 | start [--focus <任务>]    开始新会话，加载上下文
  结束 | end [摘要]                结束当前会话并附带摘要
  列表 | list                      显示近期会话

选项:
  -h, --help                       显示帮助
EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

subcmd="$1"
shift

case "$subcmd" in
    -h|--help|帮助) usage; exit 0 ;;
esac

dt_require_init

ACTIVE_SESSION_FILE="$DEVTRACK_DIR/.active_session"

session_start() {
    local focus=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --focus) focus="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "未知选项: $1" >&2; exit 1 ;;
        esac
    done

    if [ -f "$ACTIVE_SESSION_FILE" ]; then
        active="$(cat "$ACTIVE_SESSION_FILE")"
        dt_warn "已有活跃会话: $active"
        dt_warn "请先运行 'devtrack 会话 结束'，否则旧会话将被自动关闭。"
        session_end "被新会话自动关闭"
    fi

    local ts
    ts="$(dt_timestamp)"
    local session_file="$DEVTRACK_SESSIONS/${ts}.md"

    echo "$ts" > "$ACTIVE_SESSION_FILE"

    mkdir -p "$DEVTRACK_SESSIONS"
    cat > "$session_file" << EOF
# 会话: $ts
开始时间: $(dt_iso_timestamp)

## 会话开始时的上下文
EOF

    if [ -f "$DEVTRACK_STATE" ]; then
        local focus_task
        focus_task="$(grep -A 3 '^current_focus:' "$DEVTRACK_STATE" 2>/dev/null | grep 'task:' | head -1 | sed -E 's/.*task:\s*"?([^"]*)"?.*/\1/' || true)"
        local last_cp
        last_cp="$(dt_yaml_get "$DEVTRACK_STATE" "last_checkpoint" "")"
        [ -n "$focus_task" ] && echo "- 焦点: $focus_task" >> "$session_file"
        [ -n "$last_cp" ] && echo "- 最近检查点: $last_cp" >> "$session_file"
    fi

    if [ -n "$focus" ]; then
        echo "- 本次会话焦点: $focus" >> "$session_file"
        local tmp
        tmp="$(mktemp)"
        sed -E "s|^(  task:).*|\1 \"$focus\"|" "$DEVTRACK_STATE" > "$tmp"
        sed -i -E "s|^(  status:).*|\1 \"in_progress\"|" "$tmp"
        mv -f "$tmp" "$DEVTRACK_STATE"
    fi

    cat >> "$session_file" << 'EOF'

## 工作日志
<!-- AI: 在会话期间在此追加记录 -->

## 摘要
<!-- 会话结束时填写 -->
EOF

    dt_timeline_append "session_start" "会话已开始: $ts"

    dt_info "会话已开始: $ts"
    dt_info "会话文件: $session_file"

    dt_info ""
    dt_info "正在加载当前上下文..."
    "$SCRIPT_DIR/devtrack-context.sh"
}

session_end() {
    local summary="${*:-未提供摘要}"

    if [ ! -f "$ACTIVE_SESSION_FILE" ]; then
        dt_die "无活跃会话。请先运行 'devtrack 会话 开始'"
    fi

    local active_ts
    active_ts="$(cat "$ACTIVE_SESSION_FILE")"
    local session_file="$DEVTRACK_SESSIONS/${active_ts}.md"

    if [ -f "$session_file" ]; then
        cat >> "$session_file" << EOF

---
结束时间: $(dt_iso_timestamp)

## 会话摘要
$summary
EOF
    fi

    rm -f "$ACTIVE_SESSION_FILE"

    dt_timeline_append "session_end" "会话已结束: $active_ts - $summary"
    dt_yaml_set "$DEVTRACK_STATE" "updated_at" "$(dt_iso_timestamp)"

    "$SCRIPT_DIR/devtrack-context.sh" > /dev/null 2>&1 || true

    dt_info "会话已结束: $active_ts"
    dt_info "摘要: $summary"

    if [ -d ".ccb/history" ]; then
        local ccb_file=".ccb/history/devtrack-${active_ts}.md"
        cp "$DEVTRACK_CONTEXT" "$ccb_file" 2>/dev/null || true
        dt_info "上下文已同步到: $ccb_file（供 continue skill 使用）"
    fi
}

session_list() {
    if [ ! -d "$DEVTRACK_SESSIONS" ]; then
        dt_info "暂无会话记录。"
        return 0
    fi

    echo "=== 近期会话 ==="
    echo ""

    local active_ts=""
    [ -f "$ACTIVE_SESSION_FILE" ] && active_ts="$(cat "$ACTIVE_SESSION_FILE")"

    ls -1r "$DEVTRACK_SESSIONS"/*.md 2>/dev/null | head -10 | while IFS= read -r sf; do
        local basename
        basename="$(basename "$sf" .md)"
        local started ended summary

        started="$(grep -E '^(开始时间|Started):' "$sf" | head -1 | sed -E 's/^(开始时间|Started):\s*//' || true)"
        ended="$(grep -E '^(结束时间|Ended):' "$sf" | head -1 | sed -E 's/^(结束时间|Ended):\s*//' || true)"
        summary="$(sed -n '/^## (会话摘要|Session Summary)/,/^##/p' "$sf" | grep -v '^##' | head -1 | sed 's/^[[:space:]]*//' || true)"

        if [ "$basename" = "$active_ts" ]; then
            echo "  * $basename （活跃中）- 开始于 $started"
        elif [ -n "$ended" ]; then
            echo "    $basename - $started 至 $ended"
            [ -n "$summary" ] && echo "      $summary"
        else
            echo "    $basename - 开始于 $started（未结束）"
        fi
    done
}

case "$subcmd" in
    start|开始)  session_start "$@" ;;
    end|结束)    session_end "$@" ;;
    list|列表)   session_list "$@" ;;
    *)           echo "未知子命令: $subcmd" >&2; usage >&2; exit 1 ;;
esac
