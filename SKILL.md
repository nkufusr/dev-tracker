---
name: dev-tracker
description: Use when starting a new AI conversation on any project to load development state, when finishing work to save progress, or when needing to undo changes from the last session
---

# dev-tracker: AI 开发状态自动追踪

## Overview

自动追踪所有文件变更，3 个命令管理开发状态。每次会话自动快照，支持一键回滚。

## When to Use

- **新对话开始**: 检查项目是否有 `.devtrack/` 目录，有则运行 `devtrack 开始`
- **工作完成时**: 运行 `devtrack 结束 "做了什么"`
- **出问题要恢复**: 运行 `devtrack 回滚`

## Commands

| 命令 | 功能 |
|------|------|
| `devtrack 开始` | 自动快照当前状态 + 生成 AI 上下文 |
| `devtrack 结束 [摘要]` | 自动保存所有变更 + 记录差异 |
| `devtrack 回滚` | 恢复到上次会话开始前（默认预演，--apply 执行） |

## AI Integration Rules

1. **每次新对话**: 若 `.devtrack/` 存在，先运行 `devtrack 开始`
2. **结束工作时**: 运行 `devtrack 结束 "简述本次工作"`，AI 应主动提醒
3. **回滚**: `devtrack 回滚` 预演，确认后 `devtrack 回滚 --apply`

## How It Works

`devtrack 开始` 自动快照所有追踪文件（本地+远程），然后输出上下文摘要。
`devtrack 结束` 再次快照，自动对比找出变更/新增/删除的文件并记录。
`devtrack 回滚` 从"开始前快照"恢复所有文件到会话开始前的状态。

每个会话存储在 `.devtrack/sessions/<timestamp>/`:
- `snapshot-before/` — 会话开始前的文件快照
- `snapshot-after/` — 会话结束后的文件快照
- `changes.md` — 自动生成的变更记录
- `session.yaml` — 会话元数据
