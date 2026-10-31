# Contributing to AgentDock

## Prerequisites

- macOS 13+
- Swift 6 toolchain with SwiftUI (Xcode or Command Line Tools)
- Node.js 20+ for OpenCode hook tests (`Tests/OpenCodeHooks/`)

## Build

From the repository root (`agent-dock-app/`):

```bash
./scripts/bundle.sh
open build/AgentDock.app --args --show-window
```

| Script | Purpose |
| --- | --- |
| `scripts/bundle.sh` | Release build → `build/AgentDock.app` (ad-hoc sign, or Developer ID if `SIGNING_IDENTITY` is set) |
| `scripts/notarize.sh` | Signs, submits DMG to Apple notary, staples, writes `dist/AgentDock-*-arm64.dmg`, copies `AgentDock.dmg` to landing `public/downloads/` |

See [docs/RELEASING.md](docs/RELEASING.md) for notary credentials and shipping checks.

## Tests

```bash
swift test
node --experimental-vm-modules --test Tests/OpenCodeHooks/observer.test.mjs
```

If Swift Testing macros fail under Command Line Tools alone, use Xcode or set `SDKROOT` to a complete macOS SDK.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Sources/AgentDock/App/` | App entry, delegate, menu bar, windows, preferences, control-center model |
| `Sources/AgentDock/Core/` | Session state, models, transcripts, integration errors |
| `Sources/AgentDock/Core/Support/` | Theme and fonts |
| `Sources/AgentDock/Adapters/<Provider>/` | Per-agent hooks, installers, event parsing |
| `Sources/AgentDock/Services/` | Bridge, runtime, focus, sounds, CLI install, usage fetchers |
| `Sources/AgentDock/Services/Usage/` | Usage tab models and provider CLI fetchers |
| `Sources/AgentDock/Notch/` | Notch window and geometry |
| `Sources/AgentDock/Views/` | SwiftUI pages; shared UI under `Views/Components/` |
| `Resources/` | `Info.plist`, icons, fonts, sounds, hook scripts (see [Resources/README.md](Resources/README.md)) |
| `Tests/AgentDockTests/` | Swift regression tests |
| `Tests/OpenCodeHooks/` | OpenCode plugin tests |
| `docs/` | Release documentation |
| `scripts/` | Bundle and notarize automation |

## Conventions

- **Single session brain:** `AgentStateManager.shared` owns notch-visible session state; adapters feed it events.
- **Local bridge:** Loopback-only HTTP with per-launch token; never log or copy the token into diagnostics.
- **Hooks:** Non-blocking, fail-safe; preserve unrelated user hook configuration when installing.
- **Provider boundaries:** Add provider-specific code under `Adapters/<Name>/`, not in generic views.
- **Tests:** Add or update tests for parsing, hooks, and usage behavior you change.

Do not commit `build/`, `dist/`, `.build/`, credentials, local agent config, or files listed in [.gitignore](.gitignore) (binaries, notary logs, `.env`, editor folders).

## Pull requests

Keep diffs focused, describe manual verification per affected agent, and run relevant tests before opening a PR.
