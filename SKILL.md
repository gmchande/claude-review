---
name: claude-review
description: Single-session Claude Opus 5 review gate for a current diff, branch, plan, artifact, or coordinated multi-repo change. Launch one visible read-only Claude TUI in a right-hand Cmux split or Ghostty tab, let the user steer it, independently judge its findings against the real files, and stop for approval before editing.
---

# Claude Review

Run one independent Claude Opus 5 review in a native terminal pane. Treat its findings as input, not authority.

## Gate

Do not edit, format, generate, stage, commit, or push before the verification checkpoint. Always stop for approval after the checkpoint, even when the user also requested fixes.

## Launch

1. Run from the primary repo root.
2. If this task already has a printed Claude session, keep using it. Never launch another review or retry a failed run without the user's explicit approval.
3. Launch one review with host access. A sandboxed launch cannot use the Cmux control socket, Ghostty automation, or the user's Claude login.

```sh
/path/to/claude-review/scripts/claude_review.rb \
  --intent "Short description of the change"
```

Useful options:

- `--include-repo PATH` adds another repo's authority, status, diff, and eligible untracked text; repeat as needed.
- `--plan PATH` supplies a plan or PRD and becomes plan-only when the worktree is clean.
- `--artifact PATH` supplies a document or workflow and becomes artifact-only when the worktree is clean.
- `--base REF` reviews committed primary-branch work when no worktree change is available.
- `--resume-run PATH --intent TEXT` reuses the exact printed Claude session for an approved follow-up, opens it in the viewer selected from the current environment, and waits for that new turn.
- `--dry-run` prints the bundle without launching Claude.

Inside Cmux, the launcher opens a vertical terminal split on the right. Otherwise it opens a Ghostty tab. It does not use Zellij. The launcher prints the viewer, handoff path, marker path, and exact resume command.

Claude starts in the primary repository, not the temporary run directory. The private run directory contains only the bundled request, per-run settings, launcher, launch acknowledgement, marker, and handoff. The launcher reports success only after `start-review` acknowledges that it executed.

Claude is pinned to `claude-opus-5` at `xhigh` effort and receives only `Read`, `Grep`, and `Glob`. Bash, editing, web, MCP, subagent tools, and automatic model fallback are unavailable. The handoff is rejected if the recorded transcript contains another real assistant model or no real assistant-model evidence. Claude Code's synthetic error entries are not models. Likely credential paths are excluded from untracked bundles, but this is not a secrets scanner.

## Observe

- Let the user watch the visible Claude TUI. Press Escape to interrupt the current turn, type a correction, and press Enter. Press Ctrl+D only when finished; it is not needed to produce the handoff.
- If Claude asks the user to approve the per-run command hooks at startup, let the user review them in the TUI. Approve them to enable the handoff; if declining, exit Claude so the launcher can terminate. Do not bypass the dialog.
- Run the launcher as a long-running tool call. Its local watcher stays silent while marker `running` means a turn is active or was interrupted and awaiting correction. Marker `0` is complete, `130` means Claude closed before completing the current turn, and `1` is failed.
- If the tool call yields a process handle, wait on that same process. Do not repeatedly inspect the marker or terminal, and do not ask the user to tell you when Claude is done. The local wait consumes no review-model tokens.
- When the launcher returns, read the marker and handoff once. Read the terminal screen only when the user reports a problem and the marker is insufficient to diagnose it.
- If the pane is gone and the marker remains ambiguous, report that and ask the user; never relaunch automatically.
- Leave the session open for follow-ups until the user says it is finished. Start an approved follow-up with the printed `--resume-run` command so the existing session, viewer selection, fresh-turn marker, and watcher are reused together.
- The per-run settings allowlist exposes Claude Opus 5. Do not choose Default or use `/model` to leave Opus 5. Confirm the TUI header shows Opus 5 with xhigh effort. If another model appears, reject the handoff and report the run as invalid.

## Verify and Stop

After the latest marker contains `0`:

1. Read the findings-only handoff first, then inspect the changed-file summary.
2. Verify each finding against its cited lines, necessary surrounding logic, and directly relevant tests or callers. Do not reload the full review bundle or duplicate Claude's broad review.
3. Make one bounded independent pass over the changed boundaries, immediate callers, and focused tests to catch material omissions. Expand further only when a finding cannot otherwise be resolved or a material risk is clearly under-reviewed. Apply the same proportional check across included repositories and supplied artifacts.
4. Classify each finding as accepted, rejected, or deferred. Judge Claude's depth and priorities, identify material omissions, and reject pedantry, speculation, or unnecessary redesign.
5. Report this checkpoint and stop:

```md
Claude reported:
- [short findings]

My independent assessment:
- Actual change: [what it does and its material risks]
- Review quality: [appropriately scoped, overreaching, incomplete, or mixed]
- Missed or under-reviewed: [important omissions, or none]

Accepted:
- [finding]: [why]

Rejected or deferred:
- [finding]: [why]

Implementation plan:
- [smallest edits]
- [focused checks]

Waiting for your go-ahead before I edit.
```

If Claude reports nothing or gives an incomplete answer, inspect the change boundaries and highest-risk paths before judging the result. Do not redo the entire review or treat the absence of findings as validation by itself.

## After Approval

Fix only accepted in-scope findings and rerun focused checks. Use the printed `--resume-run` command only when the fixes materially change the review target.
