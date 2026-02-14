# MEMORIES

## Active Context
- Scope: Project
- Current focus:
- Open threads:
- Last updated: YYYY-MM-DD

## Entry Template
- Date: YYYY-MM-DD
- Task title:
- Category: Episodic | Semantic | Procedural
- What happened:
- What was learned:
- Better prompt suggestion for Ramiro:
- Current decision/next step:

## 2026-02-14
- Task title: Pull latest upstream changes
- Category: Procedural
- What happened: Ran session-start protocol (loaded AGENTS.md, ensured project memory file exists) then executed `git pull --ff-only`.
- What was learned: `git pull` may appear to hang while negotiating/fetching large objects; this update included a ~75MB Windows binary (`dist/windows-x64/codex.exe`).
- Better prompt suggestion for Ramiro: If you want speed, ask to pull with progress (`git -c fetch.prune=true pull --ff-only --progress`) and note if large binaries/tags are expected.
- Current decision/next step: Repo is updated to `54a7f98`; proceed with whatever task depends on the latest code.

## 2026-02-14
- Task title: Fix CI packaging paths for CLI binaries
- Category: Procedural
- What happened: I checked workflow run 22007829002 and confirmed both Linux and Windows jobs failed because `cp` expected `.../resources` directories under extracted app trees. I patched `.github/workflows/build-release.yml` to create `resources` and `resources/bin` before copying CLI binaries in both `build-linux` and `build-windows`.
- What was learned: Upstream ASAR extraction/move flow doesn’t guarantee `app/resources` exists, so unconditional `mkdir -p` is required before `cp` for both OS jobs.
- Better prompt suggestion for Ramiro: When asking for CI fixes, include the exact copy destination path and whether intermediate directories exist, so workflow preconditions can be hardened in one edit.
- Current decision/next step: Commit this workflow patch, push, and run a follow-up tag-triggered CI.
