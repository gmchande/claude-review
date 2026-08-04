# claude-review

A Codex skill that opens one read-only Claude Opus 5 review in a visible terminal, then returns Claude's findings to Codex for independent verification before any edits.

## Requirements

- macOS
- Codex
- Claude Code, signed in with access to Opus 5
- Git, Ruby, and zsh
- Cmux or Ghostty

Inside Cmux, Claude opens in a right-hand split. From the Codex app or anywhere else, it opens in a Ghostty tab.

## Install

```sh
git clone https://github.com/gmchande/claude-review.git "$HOME/.agents/skills/claude-review"
```

Codex discovers personal skills in `~/.agents/skills`. Restart Codex if the skill does not appear immediately.

## Use

Ask Codex to run:

```text
$claude-review
```

Codex bundles the current change, opens an interactive Claude TUI, waits locally for Claude to finish, verifies the findings, and stops for approval before editing.

The runner also supports plans, artifacts, committed branch work, and coordinated changes across repositories:

```sh
~/.agents/skills/claude-review/scripts/claude_review.rb --help
```

Claude is pinned to `claude-opus-5` at `xhigh` effort with only `Read`, `Grep`, and `Glob`. It cannot edit files, run shell commands, browse the web, use MCP servers, or switch models.

The runner skips likely credential filenames when bundling untracked files, but it is not a secrets scanner. Review only repositories you trust.

## Check

```sh
ruby scripts/self_check.rb
```

MIT licensed.
