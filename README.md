# dev-tracker — AI 开发状态追踪工具

自动化追踪开发状态，支持检查点快照与全栈回滚（代码 + 状态 + 远程服务器）。

让 AI 开发工具（Cursor / Claude Code / Codex）在新对话中**5 秒内恢复上次工作状态**。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nkufusr/dev-tracker/main/install.sh)
```

或手动安装：

```bash
git clone https://github.com/nkufusr/dev-tracker.git ~/.local/share/dev-tracker
~/.local/share/dev-tracker/install.sh
```

## 命令一览

所有命令支持**中文和英文**双语：

| 中文 | English | 功能 |
|------|---------|------|
| `devtrack 初始化` | `devtrack init` | 初始化项目追踪 |
| `devtrack 检查点 <标签>` | `devtrack checkpoint <label>` | 创建检查点快照 |
| `devtrack 上下文` | `devtrack context` | 生成 AI 可读的上下文摘要 |
| `devtrack 状态` | `devtrack status` | 显示当前开发状态 |
| `devtrack 对比` | `devtrack diff` | 对比文件与检查点差异 |
| `devtrack 回滚 <名称>` | `devtrack rollback <name>` | 恢复到检查点 |
| `devtrack 会话 开始` | `devtrack session start` | 开始会话记录 |
| `devtrack 会话 结束` | `devtrack session end` | 结束会话记录 |
| `devtrack 帮助` | `devtrack --help` | 显示帮助 |

## 快速开始

```bash
cd your-project/
devtrack 初始化 --name "MyProject"
# 编辑 .devtrack/config.yaml 和 state.yaml
devtrack 检查点 初始版本
# ... 做一些修改 ...
devtrack 对比
devtrack 回滚 初始版本 --dry-run   # 预演
devtrack 回滚 初始版本 --apply     # 执行
```

## 工作原理

```
.devtrack/
  config.yaml           # 项目配置（追踪路径、远程服务器、构建命令）
  state.yaml            # 当前开发状态（任务、焦点、阻塞、风险）
  timeline.yaml         # 事件时间线
  context.md            # 自动生成的 AI 上下文摘要
  sessions/             # 会话日志
  checkpoints/          # 检查点快照
    <时间戳>-<标签>/
      manifest.json     # 文件清单 + SHA-256
      originals/        # 文件备份（本地 + 远程）
      rollback.sh       # 自动生成的回滚脚本
      verify.sh         # 自动生成的验证脚本
```

## 依赖

- `bash` (4.0+)
- `jq`
- `ssh` / `scp`（仅远程功能需要）

## License

MIT
