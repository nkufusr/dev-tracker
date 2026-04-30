# dev-tracker — AI 开发状态自动追踪

每次 AI 对话**自动快照所有文件**，支持一键回滚。只需 3 个命令。

## 特性

- **3 个核心命令** — 开始 / 结束 / 回滚
- **空间高效** — 跨代硬链接去重 + zstd 压缩 + 自动尊重 `.gitignore`，**节省 50-95%** 空间
- **中断恢复** — 长时间无对话或异常中断后，`devtrack 结束` 能自动找回孤儿会话
- **智能备注** — 不传 summary 时按文件路径自动分类生成（API / 模型 / 测试 / 前端 等 18 类）
- **多 AI 工具** — Cursor / Claude Code / Codex 一键集成

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
devtrack 结束 "实现了XX功能"       # 显式备注
# 或者
devtrack 结束                      # 自动生成备注（如 "API: users, auth | 测试: test_users [+340/-15]"）

devtrack 回滚                      # 预演回滚
devtrack 回滚 --apply              # 一键恢复到上次开始前
```

## 工作原理

| 命令 | 背后做了什么 |
|------|------------|
| `devtrack 开始` | 记录所有文件的 SHA-256 基线（轻量，无文件复制） + 生成 AI 上下文摘要 |
| `devtrack 结束` | 对比基线找出变更/新增/删除 → 创建全量回滚包（硬链接 + 压缩） → 轮转历史 |
| `devtrack 回滚` | 默认预演；`--apply` 一键恢复（自动解压 .zst） |

### `devtrack 结束` 的鲁棒性

按以下顺序尝试恢复，确保命令总能完成：

1. **`.active_session` 存在** → 正常结束流程
2. **孤儿会话**（标记丢失但 `sessions/<id>/session.yaml` 是 `active`/`failed` 状态） → 自动恢复并继续
3. **无活跃会话但有文件变更** → 提示创建补录会话（基于最近 completed 会话的基线）
4. **无变更** → 报错 `没有活跃会话`

### 智能自动备注

不传 summary 时按文件路径模式自动分类：

| 类别 | 触发模式 | 示例输出 |
|---|---|---|
| API | `api/`、`routes/`、`handlers/` | `API: users, auth` |
| 模型 / Schema | `models/`、`schemas/`、`dto/` | `模型: user` |
| 测试 | `tests/`、`*_test.*`、`*.spec.*` | `测试: test_users (+2)` |
| 前端 | `components/`、`pages/`、`stores/` | `组件: AppLayout` |
| 文档 / 配置 / 迁移 / CI / 构建 / 脚本 | … | … |

git 仓库会自动追加 `[+340/-15]` 行数统计。

### 存储优化

```yaml
# .devtrack/config.yaml
storage:
  rollback_keep: 3          # 保留几代历史回滚（默认 3 + 当前 = 4）
  respect_gitignore: true   # 自动剔除 node_modules/build/.venv 等
  dedup_strategy: hardlink  # 同分区下未变文件硬链接到上一代，零额外空间
  compress: true            # zstd 压缩（要求 zstd 命令）
```

**实测对比**（30 文件 Python 项目，5 次会话）：

| 维度 | 无优化 | 优化后 | 节省 |
|---|---|---|---|
| 4 代历史总占用 | 672K（4× 全量） | 300K（1 全量 + 3 增量） | **55%** |

加上自动尊重 `.gitignore`，**真实大型项目可达 95%+ 节省**。

### 目录结构

```
.devtrack/
├── config.yaml          # 项目配置（追踪路径、远程、storage 选项）
├── state.yaml           # 当前状态
├── timeline.yaml        # 事件时间线
├── context.md           # AI 上下文（每次结束自动更新）
├── .active_session      # 当前活跃会话标记
├── sessions/<id>/
│   ├── baseline.json    # 会话开始时的轻量 SHA 基线
│   ├── session.yaml     # 会话元数据 + 备注
│   ├── changes.md       # 变更记录（修改/新增/删除分类）
│   └── activity.jsonl   # AI 操作日志（如有 hook）
├── rollback/            # 当前可用回滚包（全量备份，压缩 + 硬链接）
├── rollback.1/          # 上次会话的回滚包
├── rollback.2/
└── rollback.3/
```

## 支持的 AI 工具

安装脚本自动链接到：
- Cursor (`~/.cursor/skills-cursor/`)
- Claude Code (`~/.claude/skills/`)
- Codex (`~/.codex/skills/`)

## 依赖

- 必需：`bash` (4.0+)、`jq`、`sha256sum`
- 可选：
  - `rg` (ripgrep) — 加速文件扫描
  - `zstd` — 启用压缩（无则自动退回未压缩）
  - `git` — 启用智能备注的行数统计
  - `ssh`/`scp` — 远程文件追踪

## License

MIT
