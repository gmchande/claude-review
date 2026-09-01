# Plan: Ghostty `claude` path and Cmux fallthrough

The launcher already opens a visible review and waits on the marker. Two leftover holes from that work: Ghostty can fail to find `claude`, and a dead Cmux CLI still steals the dispatch. This slice closes those. It does not touch `empty_tree_ref`.

## Essence

- The generated start script runs the `claude` binary the wrapper already found. Not a login shell, not a name on the window's `PATH`.
- Dispatch matches preflight. Cmux only if we are in Cmux *and* its CLI is there. Otherwise Ghostty if it is actually there, else Omarchy.

## Not this

- No `zsh -lc` and no `$SHELL -lc`.
- No `--viewer` flag and no new Ruby file.
- No `empty_tree_ref` change.
- No second Linux test suite and no PATH hiding to fake a missing `cmux`.

## Ghostty / every backend

In `claude_args`, the first token is `ClaudeVisibleSession.command_path("claude")`, not `"claude"`. `preflight!` already requires `claude` on the wrapper's `PATH`. Baking that path is the same idea as the absolute `omarchy` spawn.

Do not special-case mise. If `command -v` returns a shim, that is what the wrapper would have run.

## Cmux

In `run_review` and `current_viewer_name`, the Cmux branch is `cmux_context? && cmux_command_path`. Same test `preflight!` already uses. `ensure_cmux_ready!` stays on the Cmux path only.

## Tests

Keep the existing Cmux-present and Ghostty-when-available cases.

Add one case in `test_native_viewer_selection`: Cmux env vars set, no bundled CLI. If `cmux_command_path` is nil, Ghostty wins. If this machine has `cmux` on `PATH`, skip that assertion. Do not hide `cmux` on `PATH`.

In `test_generated_resume_script`, the written `start-review` contains the absolute `claude` from that run's `PATH` (the fake in `scratch`).

`ruby scripts/self_check.rb` on this machine is the check.
