# AIrail — TODO / where we left off

_Last updated: 2026-09-02. v2 accounts + live data + card detail landed
(uncommitted at time of writing — review, then commit). Settings is now
General · Rail · Accounts; four of five providers read real numbers._

## Decisions made (2026-09-02)

1. **Real numbers over purity.** Reading other tools' sign-ins (Keychain,
   local files) and calling their usage endpoints is in. README privacy line
   was rewritten accordingly.
2. **ChatGPT is merged into Codex.** One OpenAI account; ChatGPT has no usage
   API. The Add Account sheet explains it; the Codex tile says "covers ChatGPT".
3. **Cursor reads `state.vscdb`.** Unofficial; the account page carries a
   "can break without warning" caveat and degrades to `stale`/`error`.
4. **Rail membership is accounts-based.** Connected + "Show on rail" replaces
   the old enable toggles. No accounts → demo rail for detected tools with a
   "Connect…" link in the overlay.

## How each account connects (all verified live on this Mac)

| id | sign-in source | usage source | notes |
| --- | --- | --- | --- |
| claude | Keychain item `Claude Code-credentials` → `claudeAiOauth.accessToken` (+`expiresAt` ms, `subscriptionType`) | `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) → `five_hour`/`seven_day` `.utilization`, `.resets_at` (6-digit fraction) | 7-day chart from `~/.claude/projects/**.jsonl` assistant lines, deduped on `message.id:requestId`. Token cached in memory; Keychain re-read only after expiry (each read may prompt). |
| codex | `~/.codex/auth.json` → `tokens.access_token`, `account_id`; id_token claims give email + `chatgpt_plan_type` | `GET chatgpt.com/backend-api/wham/usage` + `chatgpt-account-id` → `rate_limit.primary_window`/`secondary_window` (told apart by `limit_window_seconds`) | chart from `~/.codex/sessions/**.jsonl` `token_count` → `last_token_usage.total_tokens` (sums exactly to session total). Session files also carry `rate_limits` — unused fallback. |
| copilot | `gh auth token`, else `~/.config/github-copilot/apps.json` `oauth_token` | `GET api.github.com/copilot_internal/user` → `quota_snapshots.premium_interactions` (falls back to `chat` when entitlement is 0), `copilot_plan`, `quota_reset_date` | monthly meter → `periodLabel` "monthly premium"/"monthly chat". No local history source. |
| cursor | `state.vscdb` `ItemTable` keys `cursorAuth/accessToken`, `cachedEmail`, `stripeMembershipType`; JWT `sub` → user id | `GET cursor.com/api/usage-summary` with cookie `WorkosCursorSessionToken=<id>%3A%3A<token>` → `individualUsage.plan.totalPercentUsed`, `billingCycleEnd`, `membershipType` | raw `used/limit` units are undocumented, so only the percent is shown. |
| gemini | `~/.gemini/oauth_creds.json` exists on some Macs (not this one) | none verified | listed as "Coming soon", `fetchUsage` throws `.unsupported`. |

Endpoints are unofficial; if one changes, `LiveProviderTests` (run with
`TEST_RUNNER_AIRAIL_LIVE=1`) is the fastest way to see what broke.

## Card detail (2026-09-02, later the same day)

Added `UsageDetail` (hourly + daily buckets, week aggregate, meters) behind
every snapshot. Overlay now: meters list → `24 Hours | 7 Days` chart with hover
callout and 5-hour session shading → by-model / by-project columns → activity
line. Sources:

- Claude/Codex: `TranscriptScanner` now carries model, project (cwd basename),
  session id, tool calls and thinking/reasoning tokens; Codex needs per-file
  context (`session_meta` → `turn_context` → `token_count`). Tool calls count
  on every line, tokens dedup on `message.id:requestId`.
- Cursor: `POST cursor.com/api/dashboard/get-filtered-usage-events` (needs
  `Origin: https://cursor.com`, `pageSize` 1000 works) → per-request events
  with model, token split, `totalCents`, `conversationId`. Fetched
  incrementally since the newest known event. `get-aggregated-usage-events`
  also works but isn't needed. On-demand spend units are undocumented — not
  shown.
- Copilot: all meters from `quota_snapshots` (zero-entitlement ones dropped).
- Cursor's raw `used/limit` and the "$" per model are Cursor's own accounting
  (cost is kept in `UsageAggregate.cost`, shown in the hover callout only).

Open polish: hover callout was only eyeballed in code (the overlay closes on
any outside click, so it couldn't be screenshotted); demo hourly shape is a
fixed working-day curve.

## Other… accounts + notch mode (2026-09-02, evening)

- **Keyed platforms** (`KeyedPlatform.catalog`, `KeyedProvider`): OpenRouter
  (`/api/v1/auth/key` + `/api/v1/credits`), DeepSeek (`/user/balance`),
  Anthropic API (`/v1/organizations/usage_report/messages` + `cost_report`,
  admin key), OpenAI API (`/v1/organization/usage/completions` + `/costs`,
  admin key). Keys live in AIrail's own Keychain item (service "AIrail",
  account = platform id). **Parsers follow the docs but are NOT yet verified
  against a real key** — no keys on this Mac. Run
  `TEST_RUNNER_AIRAIL_LIVE=1 TEST_RUNNER_AIRAIL_<PLATFORM>_KEY=… xcodebuild test
  -only-testing:AIrailTests/LiveProviderTests` with the first real key and fix
  whatever the response actually looks like. Known guesses: Anthropic
  `cost_report.amount` treated as minor units (cents); OpenAI costs
  `amount.value` treated as dollars.
- Decision: web-only consumer apps stay unsupported (listed in the Other page
  with a "Request a provider…" link). No cookie scraping.
- **Notch mode** (`NotchWindowController`, `NotchView`, `NotchGeometry`,
  `AppSettings.position`): verified on this MacBook's built-in display
  (220×38 pt notch) — hairline under the notch, island on hover, HUD below.
  Panel level `.statusBar` is enough to sit above the menu bar. Falls back to
  the left edge when no notch is attached; `railSide` is now derived from
  `position`. Adding a platform = one `KeyedPlatform` entry + a fixture test.

## Multi-display fix (2026-09-02, late)

The rail used `NSScreen.screens.first` (the menu-bar display). On Vincent's
desk — Dell | ultrawide (main) | MacBook — "Left" landed on the seam at x=0
and "Right" on the seam at x=3440, where the pointer just crosses to the next
display. `ScreenSelection` now picks the outer edge of the whole arrangement
(leftmost/rightmost display, taller wins ties), with Settings › Rail ›
Display to override by name (`AppSettings.railDisplay`). Notch mode is
unaffected: the island only ever lives on the notched display.

## Rate-limit handling (2026-09-02)

Claude's usage endpoint returned HTTP 429 after a burst (many rebuilds/relaunches
+ tests + the 60s timer all at once). Fixed: 429 is now `ConnectionError
.rateLimited(retryAfter:)`, honours the `Retry-After` header, and `ProviderManager`
backs the provider off (server's Retry-After, else 1→2→4→8→16 min) instead of
retrying every 60s. Stale numbers stay on screen; the account page's Refresh
button forces through the backoff. Per-account token, so per-user rate limits —
one user at 60s is fine; the burst was the cause.

## Notch/island mark polish (2026-09-02)

First render of the island read as loading spinners: `LogoMark`'s ring track
was `color.opacity(0.2)`, invisible on black, so a partial arc looked like a
spinner. Added `onDark` to `LogoMark` — a white base ring + brighter colour
track so the gauge always reads as a full circle, a clean `Color(white:0.13)`
chip instead of the frosted disc (muddy on black), heavier glyph. Island body
tightened (`markSize + 18`). Rail/overlay marks unchanged (glass path kept).

## Percent-on-hover (2026-09-02)

Island now reveals the pointed-at provider's name + ring percent (or plan) in a
caption line under the marks — `hoveredId` hoisted from `NotchMarksRow` into
`NotchView`, caption row is fixed-height so the marks never jump, fades on the
id change. `islandBodyHeight` grew to `markSize + 32` to seat it. Falls back to
the selected provider when the overlay is open.

## Island shape + motion (2026-09-02)

The island felt like a plain dropdown because it was a flat-topped rounded
rect scaling in. Added `IslandShape` / `NotchPillShape` — a silhouette whose
top edge flares to full width with concave fillets (melting into the top edge
like the notch) and necks into a convex-bottomed body. Window reserves
`islandFlare` (16pt) each side for the fillets; content inset to match. Expand
spring punchier (response 0.5, damping 0.66) for a liquid overshoot.

Possible next tuning if it still feels off: let the marks/caption fade in a
beat AFTER the shape settles (currently they scale with the container plus
their own entrance stagger), and/or a matched-geometry morph from pill to
island rather than a crossfade.

## Style pass toward the renders (2026-09-02)

- Island is now the app's frosted dark glass on a drawn Island (matches the
  `renders/` panels), and stays OLED black only on a real hardware notch so it
  merges with the cut-out — `NotchView.islandBackground` switches on
  `ui.notchIsVirtual`. Fixed the "shade": the island's drop shadow was radius
  18 / 50% black (a haze on the desktop); now a tight radius-6/10 shadow.
- Expanded edge rail shows name + percent under each mark again (render #1);
  `expandedWidth` 88→108, cell height math updated in RailWindow. Hover
  magnify now applies to the mark only, not the caption.

## Style + robustness pass (2026-09-02)

- Collapsed hairline was a rainbow (orange+green+purple stacked at once) — the
  cascade stacked with several providers. Replaced `CascadingHairline` with
  `RailHairline`: one calm periwinkle accent that breathes, never a rainbow.
- Drawn Island read as pure black on dark wallpapers (ultraThinMaterial + 24%
  black composited to near-black). New shared `GlassPanel` (dark-grey base +
  material + top highlight + light edge) used by the island and the rail card
  so it's clearly frosted glass on any wallpaper. Real hardware notch stays
  OLED black by the earlier choice — flip to glass there if wanted.
- Screen handling: the screen list often isn't final when
  didChangeScreenParameters fires (or at launch), so `applyPosition(resettling:)`
  re-asserts after a 0.4s settle. If a specific multi-display failure repeats,
  need the exact repro (which display, notch vs edge, what appeared where).

## Notch fell back to the left edge (2026-09-02)

Symptom: Built-in display + Notch, but the edge rail showed on the built-in's
left. The availability check (Settings showed "Notch available") and the
placement resolver could disagree, and the settings-change path had no retry,
so a transient mis-resolve stuck as an edge fallback. Fixes: `NotchGeometry`
now keys on `safeAreaInsets.top` for BOTH "has a notch" and `notch()` (aux
areas only refine width, centred fallback when nil), so availability and
placement can't disagree; `applyPosition(resettling:)` now also runs after a
0.4s settle on position/display changes, not just screen changes, so a
transient self-heals. Verified: built-in+notch → window at the notch (x4230),
not the left edge (x3440).

## Collapsed rail was full-height (2026-09-02)

The collapsed hairline used the same frame as the expanded card (only width
changed), so the idle line ran ~38% of screen height. Split the heights in
`RailWindow.frame(expanded:)`: expanded fits the card; collapsed is a compact
168 pt centred hover strip that grows to the card on hover.

## Two-stage expand → one motion (2026-09-02)

Hovering made the bar "get longer, then the icons open" — two steps. Causes:
(1) the collapsed hairline used `maxHeight: .infinity`, so it snapped to the
full window height the instant the window resized; (2) the marks had their own
entrance stagger on top of the card/island transition. Fixes: the collapsed
hairline is now a fixed 150 pt (edge) / fixed strip (notch), decoupled from the
window, so it never stretches; removed the per-mark entrance stagger on both
the rail card and the notch island so the whole thing reveals as one spring.
Window resize stays instant but is invisible (transparent panel); only the
card/island spring is seen. Kept the Dock-magnify-on-hover.

## Distribution (2026-09-02)

- Repo is **private** for now (Vincent-only); goes public once there's an Apple
  Developer ID. `v0.2.0` release is a **draft** with the DMG attached.
- `scripts/release.sh` builds a Release `.app` signed with the stable
  self-signed "AIrail Dev" cert and wraps it in `dist/AIrail-<version>.dmg`.
  Same cert every release ⇒ Keychain "Always Allow" persists across versions.
- No Apple Developer account yet ($99/yr; app is free, no way to recoup — fine,
  it's about getting the work out). Consequence: not notarized, so first launch
  needs a one-time right-click → Open (documented in README).
- **When the Developer ID exists (drop-in, no rework):** set
  `AIRAIL_SIGN_IDENTITY` to the Developer ID, add `--options runtime` to the
  build in release.sh, add a `notarytool submit --wait && xcrun stapler staple`
  step after the DMG, then make the repo public and publish the release.
  Optional: a Homebrew tap (`brew install --cask vincentj88/airail/airail`)
  pointing at the release DMG, and Sparkle auto-updates via a GitHub Pages
  appcast.

## App icon + update checker (2026-09-02)

- **Icon**: `Sources/AIrail/Assets.xcassets/AppIcon.appiconset`, rendered by a
  Core Graphics script (dark glass squircle, glowing periwinkle rail, three
  provider dots). Wired via `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
  MARKETING_VERSION bumped to 0.2.0.
- **UpdateChecker** (`Providers/Support/UpdateChecker.swift`): reads the repo's
  latest GitHub release, compares to the bundle version, notifies + hands off
  the DMG download. "Check for Updates…" in all menus + a daily quiet check.
  No in-place self-replace (deliberate — that's Sparkle's job). Returns 404 /
  "up to date" while the repo is private; activates when public.
- **Sparkle** is the go-public upgrade for true one-click in-place updates:
  add the SPM dependency, an EdDSA key (public key in Info.plist), an appcast
  feed (GitHub Pages or a public releases repo), and swap the checker's
  "Download" for Sparkle's updater. Needs the public feed + notarization.

## Insights (2026-09-02)

Four data-mining features on top of what's already collected:
- **Burn-rate projection** (`ProviderManager.projection(for:)` + `UsageProjection`):
  keeps 30 min of (time, ring %) samples, fits a slope, projects time-to-100%
  vs the reset time. Shown in the HUD only when meaningfully climbing.
- **Notifications** (`UsageNotifier`, UserNotifications): 75/90% thresholds
  (once per window) + window-reset detection (a ≥25pt percent drop). Global
  opt-in `notificationsEnabled` (Settings › General, default on).
- **Ambient rail colour** (`UsageSeverity` → `RailHairline` accent): calm
  periwinkle < 70%, amber 70–90%, red ≥ 90%, from the nearest-to-limit account.
- **API-equivalent value** (`ModelPricing`): estimates PAYG cost of the week's
  tokens at the dominant model's public price (cache reads dominate volume and
  are cheapest). Prices are approximate placeholders — edit `ModelPricing.table`
  with real numbers. Labelled "est." in the UI.

## Next up

- [ ] Verify the four keyed platforms against real keys (see above).
- [x] "Island" position built (2026-09-02): `NotchGeometry.virtualNotch` draws
      a 200 × menu-bar-height pill at the top centre of the chosen display;
      `NotchView` paints it black when `ui.notchIsVirtual`. Same controller as
      Notch. Settings › Rail offers Notch for the built-in display and Island
      for the rest, and swaps between them when the display changes.
- [ ] Island polish: consider hiding the pill entirely when collapsed (hairline
      only) as an option for people who find a permanent pill too much.
- [ ] Notch polish: island top corners where it grows wider than the notch;
      consider a "Both" position (island on the MacBook, rail on externals).
- [ ] AIrail's own Keychain items suffer the same ad-hoc-signing re-prompt as
      Claude's until a stable signing identity exists.

- [x] Claude connect flow clicked through by Vincent (2026-09-02) — all four
      supported accounts have gone `live` on this Mac.
- [ ] **History for Copilot**: record one sample per day in UserDefaults so
      its 7-day chart fills in over time instead of "No history yet" (Cursor
      now has real history from its events feed).
- [ ] **Stable signing identity for development.** Every ad-hoc rebuild changes
      the code signature, so the Keychain re-asks for Claude on each new build
      and killed processes leave their prompts on screen. A self-signed
      "Code Signing" certificate (Keychain Access › Certificate Assistant) set
      as `CODE_SIGN_IDENTITY` fixes it locally; Developer ID fixes it for real.
- [ ] Gemini: find a dependable quota read (Gemini CLI's Code Assist
      endpoint?) and verify on a Mac that has `~/.gemini/oauth_creds.json`.
- [ ] Refresh key-less accounts less aggressively? Each refresh is one GET per
      account at the chosen interval (default 60 s) — fine for now.

## Quick wins (any sitting)

- [ ] Real screenshots in README: `AIrail --overlay=claude`,
      `AIrail --settings=accounts`, `--add-account` open the states directly.
- [ ] Tag `v0.1.0` (demo milestone, commit 7c71ebc) and `v0.2.0` (accounts).
- [ ] App icon (rail glyph) — Settings/app switcher currently show generic.

## Later pile

- Notarized release builds + Homebrew cask (install without Xcode).
- Sparkle auto-updates.
- More providers beyond the five.

## Tuning knobs

- Hairline color rhythm: `perColorDuration` (8s/color) in
  `Sources/AIrail/Views/RailView.swift` (`CascadingHairline`).
- Rail height: `0.38` screen fraction + content-fit math in
  `Sources/AIrail/Windows/RailWindow.swift` (`frame(expanded:)`).
- Open/close springs, logo stagger (45ms), Dock-magnify (1.16×): `RailView.swift`.
- Accounts pane height (520) and width (640) in `SettingsView.swift` /
  `AccountsSettingsView.swift`.
- Stale vs error: `ConnectionError.isTransient` decides whether the last real
  numbers stay on screen.

## Notes / decisions already made

- Bundle id `com.codeandvin.airail`; MIT; GitHub-not-App-Store; not sandboxed
  (required for reading other tools' sign-ins); push via HTTPS
  (`gh auth git-credential`) — SSH key not set up on this Mac.
- Brand marks are Simple Icons (CC0) path data in `BrandIcons.swift`, drawn by
  the in-repo SVG parser (`SVGPathShape.swift`); no binary logo assets. Codex
  intentionally keeps the terminal `>_` glyph. `BrandIcons.openAI` is kept
  though ChatGPT no longer has its own provider.
- Never fake live numbers: `ok`/`live` requires a real read. Read-only always:
  no refresh tokens, nothing written to another tool's credential store, no
  tokens on disk.
- Old `enabledProviders` default is deleted on launch; replaced by
  `connectedAccounts` + `hiddenFromRail`.
