# dev-tracker — AI 开发状态自动追踪

每次 AI 对话**自动快照所有文件**，支持一键回滚。只需 3 个命令。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nkufusr/dev-tracker/main/install.sh)
```

## 使用

```bash
cd your-project/
devtrack 初始化 --name "项目名"    # 首次使用

devtrack 开始                      # 自动快照 + 生成 AI 上下文
# ... AI 帮你写代码 ...
devtrack 结束 "实现了XX功能"        # 自动保存所有变更

devtrack 回滚                      # 预演回滚
devtrack 回滚 --apply              # 一键恢复到上次开始前
```

## 工作原理

| 命令 | 背后做了什么 |
|------|------------|
| `devtrack 开始` | 快照所有追踪文件(本地+远程) → 生成 AI 上下文摘要 |
| `devtrack 结束` | 再次快照 → 自动对比找出变更/新增/删除 → 记录 |
| `devtrack 回滚` | 从"开始前快照"恢复所有文件，默认预演 |

每个会话自动存储：
```
.devtrack/sessions/<timestamp>/
  snapshot-before/    ← 开始前的完整快照
  snapshot-after/     ← 结束后的完整快照
  changes.md          ← 自动对比生成的变更记录
  session.yaml        ← 会话元数据
```

## 支持的 AI 工具

安装脚本自动链接到：
- Cursor (`~/.cursor/skills-cursor/`)
- Claude Code (`~/.claude/skills/`)
- Codex (`~/.codex/skills/`)

## 依赖

- `bash` (4.0+)、`jq`
- `ssh`/`scp`（仅远程功能需要）

## License

MIT
