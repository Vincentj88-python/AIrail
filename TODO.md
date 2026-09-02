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

## Next up

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
