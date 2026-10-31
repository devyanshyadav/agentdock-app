![AgentDock](https://agentdock.siliconapps.dev/og-image.png)

# AgentDock

**Your coding agents, beyond their windows.**

AgentDock is a free, open-source macOS companion that surfaces coding-agent work in the MacBook notch: what is running, when input is needed, and when a turn finishes. Click the notch to bring the right agent window forward; approvals and replies stay in the agent you already use.

It supports **Claude Code**, **Cursor**, **Codex**, **Antigravity**, and **OpenCode**. There is no account, license key, or cloud backend—activity is observed and processed on your Mac.

[**Download**](https://agentdock.siliconapps.dev) · [**Website**](https://agentdock.siliconapps.dev) · [Issues & contributions](https://github.com/devyanshyadav/agentdock-app/issues)

MIT licensed · [Silicon Apps](https://siliconapps.dev) · by [Devyansh](https://devyanshyadav.com)

---

## What you get

- **Notch HUD** — Agent, model, and activity line with status glow; optional sound when a session starts, needs approval, or ends.
- **Focus** — Jump to the agent surface (IDE or dedicated app) for the session shown in the notch.
- **Connect agents** — Install or verify hooks/plugins from the app; each provider has its own setup path in **Your agents**.
- **Usage** — Subscription limits and session metrics where the provider exposes them via CLI or local APIs (not estimated billing).
- **Control Center** — Home, agents, usage, settings, license (free), and about—including manual **Check for Updates**.

Updates are optional and manual from **About**; the app does not phone home for analytics.

---

## Supported agents

| Agent | How AgentDock connects |
| --- | --- |
| **Cursor** | IDE hooks + local activity logs |
| **Claude Code** | Hook scripts + optional status line for usage |
| **Codex** | Hooks + transcript monitoring (CLI and desktop) |
| **Antigravity** | Hooks + local quota API |
| **OpenCode** | Desktop plugin posting to the local bridge |

Integrations depend on upstream hook formats and app versions. A “connected” badge means local setup succeeded, not that every possible event shape is supported forever.

---

## How it works

AgentDock runs as a menu-bar app with a notch overlay. Each **adapter** turns provider events into a single **session model** (`AgentStateManager`): working, waiting for approval, completed, or error. Native lifecycle signals are authoritative; stale transcript lines alone do not start a new turn.

**Local HTTP bridge** — Agents and hooks POST to `127.0.0.1` with a per-launch token stored under `~/Library/Application Support/AgentDock/`. The bridge does not listen on the network and is not included in diagnostics exports.

**Hooks** — Shell and JS observers ship in `Resources/*Hooks/` and are installed into each tool’s expected paths when you connect that agent.

**Usage data** — Pulled on demand when you open the Usage tab (with sensible rate limits) or via provider CLIs; figures are labeled by source and missing values stay empty rather than showing zero.

For privacy-sensitive sharing, use **Settings → Support → Copy diagnostics** and review before sending—avoid tokens, credentials, or private transcripts.

---

## Requirements

- **Mac** — macOS 13 or later, **Apple Silicon**
- **Agents** — A current Claude Code, Cursor, Codex, Antigravity, and/or OpenCode install

---

## Developers

Build, test, repository layout, and pull request guidelines: **[CONTRIBUTING.md](CONTRIBUTING.md)**.

Release signing, notarization, and shipping: **[docs/RELEASING.md](docs/RELEASING.md)**.

---

## License

Original source code is under the **[MIT License](LICENSE)**. Bundled fonts, sounds, artwork, and provider trademarks have separate terms—see **[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)**.
