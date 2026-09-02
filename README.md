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

## Accounts

AIrail never asks for a password and has no sign-in of its own. Every tool it tracks is already signed in on your Mac, so **Settings › Accounts** simply lets you connect the ones you use — AIrail borrows that tool's existing sign-in, read-only, and asks the tool's own service for your plan's usage. Add and remove accounts with the `+`/`−` buttons, the way Internet Accounts or Xcode's Accounts pane work; each account page explains exactly what is read and where it goes.

| Account | What AIrail uses | What you get |
| --- | --- | --- |
| **Claude** | The sign-in Claude Code keeps in your Keychain (macOS asks you first) + your local transcripts in `~/.claude` | Real 5-hour and weekly limits from Anthropic, reset times, 24-hour and 7-day charts, usage by model and by project, thinking share, tool counts |
| **Codex** *(covers ChatGPT)* | The sign-in Codex keeps in `~/.codex` + your local Codex sessions | Real 5-hour and weekly limits from OpenAI, reset times, 24-hour and 7-day charts, usage by model and by project, reasoning share, tool counts |
| **Copilot** | Your GitHub CLI (`gh`) sign-in, or the Copilot editor extension's | Premium, chat and completion meters for the month, plan, reset date |
| **Cursor** | The sign-in Cursor stores in its local database | Included / auto / API meters for the billing cycle, plan, cycle end, and the per-request feed behind the charts and usage by model |
| **Gemini** | — | Coming soon: no dependable way to read its quota yet |
| **Other…** | An API key you paste, kept in AIrail's own Keychain item | OpenRouter (credits used / remaining), DeepSeek (balance), Anthropic API and OpenAI API (organization usage by model and month-to-date cost, with an Admin key) |

ChatGPT and Codex share one OpenAI account, and ChatGPT itself doesn't publish usage limits, so the Codex account stands in for both. Cursor has no public API — AIrail reads what its dashboard reads, which a Cursor update could break; if that happens you get a `stale` or `error` badge, never a guess.

*Other…* is Internet Accounts' "Add Other Account": platforms with a **documented** usage or credits API, connected by key. Consumer web apps without one (Perplexity, Grok, Claude.ai, ChatGPT on the web, Le Chat, Kimi) are listed there as unsupported with a link to request a provider — AIrail doesn't scrape browser cookies to fake it.

Rules AIrail holds itself to: it only ever *reads* a tool's sign-in, never uses a refresh token or writes anything back, keeps no tokens on disk, and the only network traffic is each connected tool's own usage check. If a sign-in expires, the last real numbers stay on screen marked `stale` with a note to open the tool.

## Providers

Cursor, Claude, Codex, Gemini, Copilot — real brand marks rendered from vector path data ([Simple Icons](https://simpleicons.org), CC0-1.0), tinted in the rail's provider colors. No binary logo assets are shipped; the marks live as path data in `Sources/AIrail/Views/BrandIcons.swift` and are drawn by a small built-in SVG path renderer. All trademarks belong to their respective owners and are used solely to identify the services being monitored. Codex keeps a terminal glyph (`>_`), which is its actual CLI mark.

The rail shows your connected accounts (each has a *Show on rail* switch) and sizes itself to fit.

## Notch mode

On a MacBook with a notch, **Settings › Rail › Position › Notch** folds the rail into it, Dynamic Island-style: idle, a hairline cascades under the notch; hover, and the notch grows down into a black island holding the marks and rings; click, and the HUD hangs beneath it. It uses the notch geometry macOS reports (`safeAreaInsets`, `auxiliaryTopLeft/RightArea`), works over full-screen apps, and falls back to the left edge whenever no notched display is attached (clamshell, external-only).

## The card

Click a mark for its glass HUD. Top to bottom: the session ring (or the billing-cycle/monthly ring for tools without sessions) with reset times; the provider's meters when it has several; a chart with a `24 Hours | 7 Days` switch in the style of System Settings › Battery — hover any bar or day for its tokens, requests and input/output/cache split, and for Claude and Codex the current 5-hour session window is shaded so you can see where you are in it; *by model* and *by project* lists (Screen Time-style share bars); and one line of activity — requests, sessions, thinking share, top tools. Everything below the ring comes from local transcripts or the tool's own per-request feed, never estimates.

The collapsed hairline is a subtle 3 pt line whose colors slowly cascade through the colors of the providers you have enabled, with a soft matching glow (static under Reduce Motion).

## Demo data

Until you connect an account, the rail shows demo data for the tools it detects on your Mac (a slow random walk that looks alive but is not real), every mark carries a `demo` badge, and the overlay offers a **Connect…** link. `live` only ever means a real read succeeded.

No telemetry. Nothing scraped from browsers or cookies. AIrail reads only the sign-ins of the tools you connect, after you approve each one.

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

Settings cover accounts (add, remove, show on rail), position (left, right, notch), which display the rail uses (Automatic picks the outer edge of your whole desktop, so the pointer rests on the hairline instead of sliding onto the next display), auto-hide delay, refresh interval, and launch at login.

Launch flags for development: `--settings[=accounts]` opens Settings, `--add-account[=other]` opens the Add Account sheet (or its API-key page), `--overlay=<id>` opens the overlay for a provider.

AIrail is distributed as source on GitHub, not through the App Store.

## Tests

Unit tests cover the snapshot math, the accounts model, every provider's parser (against fixtures of the real response shapes), the incremental transcript scanner, and the demo-data engine:

```
xcodebuild -scheme AIrail test
```

Opt-in smoke tests read the accounts actually signed in on your Mac (they hit real endpoints); keyed platforms join in when their key is in the environment:

```
TEST_RUNNER_AIRAIL_LIVE=1 TEST_RUNNER_AIRAIL_OPENROUTER_KEY=sk-or-… \
  xcodebuild -scheme AIrail test -only-testing:AIrailTests/LiveProviderTests
```

## License

MIT © 2026 Vincent Jacobs. See [LICENSE](LICENSE).
