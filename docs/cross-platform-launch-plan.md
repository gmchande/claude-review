# Design: one review, one wait, two ways to open a window

The skill opens a visible Claude review and waits until the turn is done. That is one idea. Mac already knows how to open the window. Linux did not. This file is the design that change follows.

## Essence

- Done means the marker is `0`. Not the TUI process.
- Show Claude means open a visible terminal and return. Cmux if we are in Cmux and its CLI is there. Else Ghostty if it is actually there. Else Omarchy if `omarchy` is on `PATH`.
- Generated launchers are `bash`. They run the `claude` path the wrapper found. `zsh` is not a dependency.
- `--base` keeps `A...HEAD` when a merge-base exists. Otherwise `git diff A` (dirty) or `git diff A HEAD` (clean). Same rule either way. An empty tree is a valid `A`.

## Not this

- No fourth backend (`xdg-terminal-exec` as its own product).
- No `--viewer` flag.
- No `capture3` of a terminal, and no spawn that closes stdin/stdout.
- No second Linux test suite and no PATH hiding to protect Ghostty tests.
- No new Ruby file.

## Linux open

`Process.spawn` the absolute `omarchy` with `launch tui --app-id=org.omarchy.claude-fable-5-review <start-review>`, the desktop session environment (`set -a; eval "$(systemctl --user show-environment)"`, `unsetenv_others: true`), inherit stdio, `Process.detach`, wait for `launched`. If `systemctl` is missing, return nil and take the warn path. The start path is the unescaped script (`Shellwords.split` of the existing escaped caller string). Cmux and Ghostty stay as they are. `eval` alone does not export new session vars; without `set -a` they never reach `env -0`. Ruby merges spawn env by default; without `unsetenv_others` the wrapping agent's `CURSOR_AGENT` and PATH leak into the new window.

## Tests

Pin the review loop and the `--base` fallback. Do not snapshot brochure copy. Do not assert Ghostty AppleScript line by line. This machine running `self_check` is the Linux check.
