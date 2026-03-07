# Devtrack End Robustness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `devtrack 开始/结束` correctly track active worktrees, count added files, and leave rollback/session state consistent when rollback package generation fails or is interrupted.

**Architecture:** Keep the current shell-script architecture, but fix it in three narrow layers: path selection, diff logic, and rollback package lifecycle. Add focused shell regression tests that exercise the scripts against temporary fake repos instead of the live Lakka tree.

**Tech Stack:** Bash, jq, mktemp, git, small shell regression tests.

---

### Task 1: Add failing tests for the three regressions

**Files:**
- Create: `tests/test_devtrack_worktree_detection.sh`
- Create: `tests/test_devtrack_added_files.sh`
- Create: `tests/test_devtrack_atomic_rollback.sh`

**Step 1: Write the failing tests**

- Worktree detection:
  - simulate running `devtrack 开始/结束` from inside a git worktree
  - expect tracked root/config to follow the active worktree, not the main checkout
- Added-file diff:
  - create a new tracked file after `devtrack 开始`
  - expect `changes.md` and session metadata to count it
- Atomic rollback:
  - force rollback package creation to fail mid-flight
  - expect the previous valid rollback package to remain intact and `.active_session` to be cleared

**Step 2: Run tests to verify they fail**

Run:

```bash
bash tests/test_devtrack_worktree_detection.sh
bash tests/test_devtrack_added_files.sh
bash tests/test_devtrack_atomic_rollback.sh
```

Expected: each test fails against the current implementation.

### Task 2: Implement minimal source changes

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `scripts/lib/snapshot.sh`
- Modify: `scripts/devtrack-start.sh`
- Modify: `scripts/devtrack-end.sh`

**Step 1: Make the scripts worktree-aware**

- Resolve the effective project root from the current git checkout/worktree instead of assuming the static root in config.
- Keep `.devtrack` state in the checkout where the user runs `devtrack`.

**Step 2: Count added files**

- Build a current manifest or path list during `devtrack 结束`
- compare it against the baseline
- report modified, deleted, and added files explicitly

**Step 3: Make rollback creation atomic**

- build the new rollback package in a temporary directory
- only replace the current `rollback/` after `manifest.json` is successfully written
- on failure or interruption, clean temp state and remove `.active_session`

### Task 3: Verify and ship

**Files:**
- Modify if needed: `README.md`
- Modify if needed: `SKILL.md`

**Step 1: Run focused tests**

Run:

```bash
bash tests/test_devtrack_worktree_detection.sh
bash tests/test_devtrack_added_files.sh
bash tests/test_devtrack_atomic_rollback.sh
```

Expected: all pass.

**Step 2: Run a manual smoke test**

- create a temp repo + worktree
- run `devtrack 开始`
- modify/add files
- run `devtrack 结束 "smoke"`
- verify:
  - `changes.md` includes modifications/additions
  - `session.yaml` is not left `active`
  - `rollback/manifest.json` exists

**Step 3: Commit and push**

```bash
git add README.md SKILL.md scripts/ tests/ docs/plans/2026-03-08-devtrack-end-robustness.md
git commit -m "fix: harden devtrack end-state handling"
git push
```
