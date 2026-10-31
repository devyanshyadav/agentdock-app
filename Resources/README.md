# Bundled resources

Assets copied into `AgentDock.app` by `scripts/bundle.sh`.

| Path | Shipped as | Notes |
| --- | --- | --- |
| `Info.plist` | `Contents/Info.plist` | Bundle metadata |
| `AppIcon.icns`, `AppLogo*.png`, menu bar PNGs | `Contents/Resources/` | App, window, and menu bar artwork |
| `Fonts/` | `Contents/Resources/Fonts/` | Bundled fonts + OFL license files |
| `Sounds/` | `Contents/Resources/Sounds/` | Optional activity cues |
| `Icons/*.pdf` | `Contents/Resources/Icons/` | In-app symbol assets (AppKit) |
| `ProviderIcons/*.png` | `Contents/Resources/ProviderIcons/` | Provider tiles in the UI |
| `*Hooks/` | `Contents/Resources/<Name>Hooks/` | Installed into user config by Connect agents |
| `OpenCodeHooks/agentdock.js` | Same | OpenCode v2 plugin |
| `wallpaper.png` | Optional | Onboarding / settings preview background |

Menu bar: `MenuBarIcon.png` (color), `MenuBarTemplate*.png` (template fallback), then `AppLogo@1x.png`.

Hook installers reference paths under the user home directory (`.cursor`, `.claude`, `.codex`, `.gemini`, `.config/opencode`); see README.
