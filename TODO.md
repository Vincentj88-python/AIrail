# AIrail — TODO / where we left off

_Last updated: 2026-09-01. v0.1 is done: rail + hover + overlay + settings all
working with demo data, real brand marks, single-color cascading hairline,
detect-based provider defaults. All 7 unit tests green. Pushed to
https://github.com/Vincentj88-python/AIrail._

## Next up: live data (v2's whole point)

Everything still shows `demo`. Replace `fetchUsage()` per provider, starting
with the tools that keep real usage data in **local files** — no network, no
auth, matches the privacy stance (no telemetry, nothing leaves the machine).

### 1. Claude Code live provider  ← START HERE
- Parse `~/.claude/projects/*/**.jsonl` transcripts: each assistant message
  carries token usage + timestamp (this is how `ccusage` works — study the
  format, do not vendor its code).
- Compute: session % (5-hour rolling block), weekly totals, real 7-day
  sparkline from daily token sums.
- Flip status `demo → ok` only when the read succeeds; `stale` when the
  newest file is old; `error` on parse failure. First real ring in the app.
- Files to touch: `Sources/AIrail/Providers/ClaudeProvider.swift`; keep
  `MockUsageEngine` as fallback when `~/.claude` is missing.
- Add tests with a small fixture .jsonl (percent math, daily bucketing).

### 2. Codex CLI — same idea with `~/.codex/sessions`.

### 3. Copilot via `gh api` (quota endpoints). Needs spawning `gh` or reading
   its token — was out-of-scope for v1, deliberate step up. Decide policy first.

### 4. Cursor / ChatGPT / Gemini — authenticated web APIs (session tokens).
   Hardest, most fragile. Stay `demo` until a clean approach exists.

## Quick wins (any sitting)

- [ ] Real screenshots of the running app in README (replace/augment the
      design renders — hairline cascade, hover stack, overlay).
- [ ] Tag `v0.1.0` GitHub release to pin the demo-data milestone.
- [ ] App icon (rail glyph) — Settings/app switcher currently show generic.

## Later pile (from the brief's own "later" list)

- Notarized release builds + Homebrew cask (install without Xcode).
- Sparkle auto-updates.
- More providers beyond the six.

## Tuning knobs (if the feel needs adjusting)

- Hairline color rhythm: `perColorDuration` (8s/color) in
  `Sources/AIrail/Views/RailView.swift` (`CascadingHairline`).
- Rail height: `0.38` screen fraction + content-fit math in
  `Sources/AIrail/Windows/RailWindow.swift` (`frame(expanded:)`).
- Open/close springs, logo stagger (45ms), Dock-magnify (1.16×): `RailView.swift`.

## Notes / decisions already made

- Bundle id `com.codeandvin.airail`; MIT; GitHub-not-App-Store; push via HTTPS
  (`gh auth git-credential`) — SSH key not set up on this Mac.
- Brand marks are Simple Icons (CC0) path data in `BrandIcons.swift`, drawn by
  the in-repo SVG parser (`SVGPathShape.swift`); no binary logo assets. Codex
  intentionally keeps the terminal `>_` glyph (its real CLI mark).
- First launch auto-enables only detected tools (falls back to all six).
- Never fake live numbers: `ok` requires a real local read.
