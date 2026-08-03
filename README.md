# Island

[![tests](https://github.com/kay-ws/herdr-island/actions/workflows/tests.yml/badge.svg)](https://github.com/kay-ws/herdr-island/actions/workflows/tests.yml)

**Find the agents that are waiting on you.**

When several coding agents run at once, the hard question is not "what are they doing" — it is "which one is stuck on me, and why". Island puts the reason an agent stopped into herdr's Agents panel, and filters that panel down to only the agents that are actually waiting.

```
┌─ Agents ───────────────────┐
│ ● api-server  ~  main      │
│   claude                   │
│   Permission: rm -rf dist  │  ← why it stopped
│                            │
│ ● docs  ~  guide           │
│   codex                    │
│   AskUserQuestion: A or B  │
└────────────────────────────┘
```

herdr already tells you an agent is `blocked`. Island tells you what it is blocked *on*.

## Install

```sh
herdr plugin install kay-ws/herdr-island
herdr plugin pane open --plugin island --entrypoint setup
```

Setup asks before each step. Nothing is written to your configuration without a prompt.

1. **Sidebar row** — appends one row to `ui.sidebar.agents.rows` so the reason is visible.
2. **Agent hooks** — adds three entries to `~/.claude/settings.json` and `~/.codex/hooks.json` so your coding agent reports why it stopped. Only agents you already have are wired: Island treats a missing `~/.claude` or `~/.codex` as "not installed" and never creates one.
3. **Migration** — if an older `herdr-jump` installation is present, offers to remove it.

Every file is backed up before it is touched, and the candidate configuration is validated with `herdr config check` before it replaces the real one. If validation fails, your configuration is left untouched.

To see what is and is not configured without changing anything:

```sh
herdr plugin action invoke island.doctor
```

## Use

| Action | Effect |
|---|---|
| `island.focus` | Show only the agents waiting on you |
| `island.unfocus` | Show everything again |
| `island.doctor` | Report what is configured, and what is not |
| `island.apply` | Add the sidebar row to `config.toml` |
| `island.revert` | Remove that row again |

Invoke any of them with `herdr plugin action invoke <name>`. `setup` and `remove` are not in this list because they ask questions, and plugin actions have no terminal — they are popup panes instead:

```sh
herdr plugin pane open --plugin island --entrypoint setup
herdr plugin pane open --plugin island --entrypoint remove
```

`apply` and `revert` are the same configuration step as `setup`'s, without the prompts — use them from scripts, or when you only want the row.

Bind the toggle if you use it often:

```toml
[[keys.command]]
key = "ctrl+shift+w"
type = "plugin_action"
command = "island.focus"
description = "Island: show agents waiting on me"
```

The filter is a declarative view: it does not rewrite your configuration, and it disappears when the plugin is disabled. Agents needing attention sort first, then by most recent state change.

## What it writes, and where

| Location | What Island adds |
|---|---|
| `config.toml` | One row: `[{ token = "$reason", fg = "#f38ba8", bold = true }]` |
| `~/.claude/settings.json` | Three hooks: `PermissionRequest` (`*`) and `PreToolUse` (`AskUserQuestion`) set the reason; `PostToolUse` clears it |
| `~/.codex/hooks.json` | The same three |

That is the whole footprint. Island owns exactly one metadata token, `$reason`, and **never writes `ui.sidebar.agents.rows_by_agent`** — that key is a complete override in herdr, so setting it makes `rows` unreachable for the listed agents and would silently disable other plugins' rows.

If `ui.sidebar.agents.rows` already exists, that one row is all Island adds. If it does not — no rows array at all, or a `[ui.sidebar.agents]` table with no `rows` key — there is nothing to append its row to, so Island materializes herdr's own default rows (state icon, workspace, agent name) alongside its own. `rows` is all-or-nothing in herdr; writing an array holding only Island's row would silently drop those defaults instead of adding to them.

Clearing is wired in two places, deliberately. herdr's own `pane.agent_status_changed` event clears the reason when a pane leaves the `blocked` state — but that event only fires on a *transition*, and a permission request that is auto-approved never blocks the agent, so nothing would clear it. A tool always finishes, so `PostToolUse` pairs reliably with whatever set the reason. That is the only clear-side hook: the earlier design cleared from three places and a manually-sent reason vanished before it could be read.

The `remove` pane undoes each step, confirming each separately.

## Using Island alongside Agent Usage

[`senna-lang/herdr-agent-usage`](https://github.com/senna-lang/herdr-agent-usage) shows context meters and provider limits. Island shows why an agent stopped. They answer different questions and are built to sit side by side — Island deliberately does not display usage or model names, so it does not duplicate that plugin.

Both contribute to the same `rows` array, so merge rather than replace. This is a working configuration with both installed:

```toml
[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "$title"],
  ["$provider", "$limit"],
  ["$context"],
  [{ token = "$reason", fg = "#f38ba8", bold = true }],
]
```

`island.apply` inserts its row into an existing `rows` array rather than replacing the table, so installing Island after Agent Usage leaves the Agent Usage rows intact. (This only applies once a `rows` array exists — see the note above for what happens when it does not.) If `rows_by_agent` is present, setup warns you — that key would make the added row invisible with no error from herdr.

## Requirements

- herdr 0.7.5 or newer
- `jq`
- `python3`, standard library only — used by `setup`, `remove`, `apply`, `revert`, `focus`, `unfocus`, and at startup. It is **not** on the reporting hot path: the hook that runs inside your coding agent is shell, `jq`, and the `herdr` CLI, so a missing or broken `python3` costs you configuration and filtering, never your agent. (Running the test suite additionally needs 3.11+, for `tomllib`.)
- Linux or macOS (both are exercised by CI on every push)

No external Python packages, no toolchain, no build step.

### Environment variables

Every path Island touches can be redirected. This is what the test suite uses, and it is also how you point Island at a non-standard layout.

| Variable | Default | Used by |
|---|---|---|
| `ISLAND_CONFIG` | `${XDG_CONFIG_HOME:-~/.config}/herdr/config.toml` | `apply`, `revert`, `setup`, `remove`, `doctor` |
| `ISLAND_CLAUDE_SETTINGS` | `~/.claude/settings.json` | hook wiring |
| `ISLAND_CODEX_HOOKS` | `~/.codex/hooks.json` | hook wiring |
| `ISLAND_CCSTATUS` | `~/.local/bin/ccstatus` | `herdr-jump` migration only |
| `ISLAND_ASSUME_YES` | unset | `1` answers yes to every `setup` / `remove` prompt |
| `ISLAND_REASON_FG` | `#f38ba8` | colour of the reason row |

`ISLAND_REASON_FG` affects only what is written. `revert` matches the row by its `$reason` token, not by colour, so it still removes a row you added under a different value — and `apply` will not add a second one.

## How it works

Three paths, deliberately separated.

**Setting the reason.** A hook in your coding agent reads the payload of a permission request or a user question, extracts one line, and reports it as pane metadata:

```
herdr pane report-metadata <PANE_ID> --source island --token reason=... --ttl-ms 900000
```

The hook exits 0 on every path. A missing `jq`, an unreachable socket, a malformed payload — none may interfere with your agent's operation. Failing to display something is acceptable; getting in the way is not.

**Clearing it.** Two triggers, because neither covers the other. A `PostToolUse` hook clears the token when the tool that caused the stop finishes — this is the reliable pair, since a tool always finishes. herdr's own `pane.agent_status_changed` event also clears it when a pane leaves the `blocked` state, which catches reasons that no tool completion follows.

**Filtering.** `agent.view.set` accepts a reported metadata token as a filter field, so the same token that is displayed is what the filter matches on:

```json
{ "op": "exists", "field": { "token": "reason" } }
```

## Troubleshooting

**Nothing appears in the panel.** Reporting a token and displaying it are separate concerns; both are needed. Run `island.doctor` first. Then check what actually arrived:

```sh
herdr api snapshot | jq '.result.snapshot.agents[] | {agent, reason: .tokens.reason}'
```

Read `agents[]`, not `panes[]` — the sidebar renders from `agents[]`.

If the token is present but nothing shows, the row is missing or shadowed: check for `rows_by_agent` in your `config.toml`. If the token is absent, the hooks are not wired — `island.doctor` reports `claude: N/3` and `codex: N/3` separately so you can tell which side is missing. `not installed` there means Island found no `~/.claude` or `~/.codex` at all, which is not a fault if you do not use that agent.

**A custom token without `$`** makes herdr reject the entire `[ui]` block. Island always writes the `$` form; if you hand-edit, keep it.

**Reasons never clear.** Check `island.doctor` reports `3/3`, not `2/3` — the clearing hook is the third entry, and an installation wired before it existed will be missing it. Re-run `setup` to add it. If it is wired and reasons still stick, confirm the plugin is enabled: a disabled plugin stops receiving `pane.agent_status_changed`, and its view is dropped too. Reasons expire on their own after 15 minutes in any case.

## Uninstall

```sh
herdr plugin pane open --plugin island --entrypoint remove
herdr plugin uninstall island
```

`remove` clears the filter, offers to unwire the agent hooks, and offers to remove the configuration row. A row you have edited by hand is left alone — the match is exact apart from the `fg` colour, so changing the colour is safe but changing the shape means Island leaves the row for you to delete.

## Acknowledgements

The name is a nod to [Vibe Island](https://vibeisland.app/), which framed the problem space — jump, monitor, approve, ask — that led this plugin to narrow to one of those verbs and do it properly.

## License

MIT. See [LICENSE](LICENSE).
