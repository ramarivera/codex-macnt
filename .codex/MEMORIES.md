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

## 2026-02-14
- Task title: Expand Windows CLI paths in release packaging
- Category: Procedural
- What happened: After your “same error on latest installer” report, I made a second hardening patch to copy the Windows CLI into all likely runtime paths (`resources/app/resources/...`, `resources/app/...`, and `resources/...`) and added explicit `test -f` checks for all six paths before NSIS build.
- What was learned: The error can persist if the app resolves CLI at a different resource root than the packaging assumption, so duplicating the binary to all expected locations is safer for now.
- Better prompt suggestion for Ramiro: If you get a runtime path error, include the exact error string and where it says it looked for the CLI; that lets us patch the precise path expectation.
- Current decision/next step: Trigger another tagged run and verify installer behavior before concluding.

## 2026-02-14
- Task title: Fix mkdir path regression in windows packaging patch
- Category: Procedural
- What happened: The previous patch failed because `resources/app/bin` was created in cp list but not guaranteed to exist. Build logs showed `cp: cannot create regular file .../resources/app/bin/codex.exe`.
- What was learned: Additive path hardening must include creating all target folders explicitly.
- Better prompt suggestion for Ramiro: Ask for explicit Windows runtime path expectations before broadening CLI path copies, so we avoid adding speculative folders.
- Current decision/next step: Commit this fix and trigger another tagged run.
