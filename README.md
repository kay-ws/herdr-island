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
2. **Agent hooks** — adds two entries to `~/.claude/settings.json` and `~/.codex/hooks.json` so your coding agent reports why it stopped.
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
| `~/.claude/settings.json` | Two hooks: `PermissionRequest` (`*`) and `PreToolUse` (`AskUserQuestion`) |
| `~/.codex/hooks.json` | The same two |

That is the whole footprint. Island owns exactly one metadata token, `$reason`, and **never writes `ui.sidebar.agents.rows_by_agent`** — that key is a complete override in herdr, so setting it makes `rows` unreachable for the listed agents and would silently disable other plugins' rows.

If `ui.sidebar.agents.rows` already exists, that one row is all Island adds. If it does not — no rows array at all, or a `[ui.sidebar.agents]` table with no `rows` key — there is nothing to append its row to, so Island materializes herdr's own default rows (state icon, workspace, agent name) alongside its own. `rows` is all-or-nothing in herdr; writing an array holding only Island's row would silently drop those defaults instead of adding to them.

Only the *setting* side is wired into your agent's hooks. Clearing happens on herdr's own `pane.agent_status_changed` event, which means one clear path instead of several, and half as much wiring in configuration you own.

`island.remove` undoes each step, confirming each separately.

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
- `python3` — used for the filter query only; the reporting hot path is shell plus the `herdr` CLI
- Linux (macOS is not supported yet — the scripts rely on GNU `mktemp`, `date` and `chmod`)

No external Python packages, no toolchain, no build step.

## How it works

Two paths, deliberately separated.

**Setting the reason.** A hook in your coding agent reads the payload of a permission request or a user question, extracts one line, and reports it as pane metadata:

```
herdr pane report-metadata <PANE_ID> --source island --token reason=... --ttl-ms 900000
```

The hook exits 0 on every path. A missing `jq`, an unreachable socket, a malformed payload — none may interfere with your agent's operation. Failing to display something is acceptable; getting in the way is not.

**Clearing it.** herdr knows when a pane leaves the `blocked` state, so a plugin event handler clears the token there. This keeps the agent-side footprint to the two entries above, and means a reason stays visible until the agent actually moves on.

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

If the token is present but nothing shows, the row is missing or shadowed: check for `rows_by_agent` in your `config.toml`. If the token is absent, the hooks are not wired — `island.doctor` reports `claude: N/2` and `codex: N/2` separately so you can tell which side is missing.

**A custom token without `$`** makes herdr reject the entire `[ui]` block. Island always writes the `$` form; if you hand-edit, keep it.

**Reasons never clear.** Clearing is driven by herdr's `pane.agent_status_changed` event. Confirm the plugin is enabled — a disabled plugin stops receiving events, and its view is dropped too.

## Uninstall

```sh
herdr plugin pane open --plugin island --entrypoint remove
herdr plugin uninstall island
```

`remove` clears the filter, offers to unwire the agent hooks, and offers to remove the configuration row. A row you have edited by hand is left alone — only an exact match of what Island inserted is removed.

## Acknowledgements

The name is a nod to [Vibe Island](https://vibeisland.app/), which framed the problem space — jump, monitor, approve, ask — that led this plugin to narrow to one of those verbs and do it properly.

## License

MIT. See [LICENSE](LICENSE).
