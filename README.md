# AIrail

A screen-edge rail for macOS that tracks usage of the AI coding tools you actually run.

No menu-bar clutter. A barely-there hairline hugs the edge of your screen; hover to expand it into a stack of provider marks with usage rings; click one for a glass HUD with session %, weekly usage, reset time, and a 7-day sparkline.

| Collapsed | Hover | Stats overlay |
| --- | --- | --- |
| ![Collapsed hairline](renders/01-collapsed-hairline.png) | ![Hover logos](renders/02-hover-logos.png) | ![Stats overlay](renders/03-stats-overlay.png) |

## Why not another menu-bar meter?

[CodexBar](https://github.com/steipete/CodexBar) is a menu-bar meter farm — tiny icons, crowded status items, and you still have to click to learn anything. AIrail competes on UX:

| CodexBar | AIrail |
| --- | --- |
| Menu bar status items | Left (or right) screen-edge rail |
| Click a tiny icon | Hover to expand, click for a HUD overlay |
| One provider at a time unless "merge icons" | All enabled tools visible as a vertical stack of logos |
| Dense inspector menus | One glass overlay: session, weekly, reset, sparkline |

## Providers (v1)

Cursor, Claude, Codex, ChatGPT, Gemini, Copilot — real brand marks rendered from vector path data ([Simple Icons](https://simpleicons.org), CC0-1.0), tinted in the rail's provider colors. No binary logo assets are shipped; the marks live as path data in `Sources/AIrail/Views/BrandIcons.swift` and are drawn by a small built-in SVG path renderer. All trademarks belong to their respective owners and are used solely to identify the services being monitored. Codex keeps a terminal glyph (`>_`), which is its actual CLI mark.

On first launch AIrail enables only the tools it detects on your Mac (falling back to all six if none are found); add or remove providers any time in Settings — the rail shows only what you enable, and sizes itself to fit.

The collapsed hairline is a subtle 3 pt line whose colors slowly cascade through the colors of the providers you have enabled, with a soft matching glow (static under Reduce Motion).

## Demo data

**This build ships with demo data.** Every number is a slow random walk that looks alive but is not real — every provider shows a `demo` badge, and the app never pretends live numbers. It does best-effort *install detection* (a read-only check for `~/.cursor`, `~/.claude`, `gh` on PATH, and so on, shown in Settings). Live provider APIs come later.

No telemetry. No network calls. Nothing scraped from browsers, cookies, or the Keychain.

## Build & Run

Requires **macOS 14+** and **Xcode 16+** (Swift 6).

```
git clone https://github.com/Vincentj88-python/AIrail.git
cd AIrail
open AIrail.xcodeproj
```

Select the **AIrail** scheme and **Run** (⌘R). The app has no Dock icon — look for the faint teal hairline on the left edge of your screen.

- **Hover** the hairline to expand the rail.
- **Click** a logo to open the stats HUD; click another logo to swap, press **Escape** or click outside to dismiss.
- **Right-click** the rail (or use the `…` menu in the HUD) for **Settings…** (⌘,) and **Quit**.

Settings cover rail side (left/right), auto-hide delay, refresh interval, per-provider toggles, and launch at login.

AIrail is distributed as source on GitHub, not through the App Store.

## Tests

Unit tests cover the snapshot percent math, the provider registry, and the demo-data engine:

```
xcodebuild -scheme AIrail test
```

## License

MIT © 2026 Vincent Jacobs. See [LICENSE](LICENSE).
