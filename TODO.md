# AIrail — TODO / where we left off

_Last updated: 2026-09-06. **v0.2.0 is feature-complete and all pushed** to the
(now private) GitHub repo; running from `/Applications` on this Mac. Below is
where we left off; the dated sections further down are the running log of how
each piece was built and why._

## Roadmap research (2026-09-05) — resume here

An 81-agent research run (competition scout, codebase scout, ten ideation
lenses, one skeptical macOS engineer per idea, a critic, a synthesis) produced
**`ROADMAP.md`** in this repo: 62 verified ideas in three tiers with build notes,
a cut list, the pricing recommendation and nine decisions. Same content as a
page: https://claude.ai/code/artifact/1b4a8ab6-0cea-47cc-989b-4fa07e31d771

**Decisions taken 2026-09-06:** Vincent went with every pick in `ROADMAP.md`
(sandbox later; names-only redaction Bool instead of a demo face; merge Notch
and Island into one "Top" position; hold the hardened-runtime hotfix for
v0.3.0; $12 soft licence after the launch; Pro labels only on the recap card
and work/personal accounts; v0.3.0 = blocks A + B + E plus the first three C
items; usage ledger on disk yes; stay dark-only). **Constraint:** the Apple
Developer ID waits until AIrail has earned the $99, so the go-public step is a
free soft launch with a Sponsors goal first, notarization + licence + Show HN
after (see "Order of work" in `ROADMAP.md`). Work started on branch
`tier1-block-a`.

Things established that reverse or extend earlier notes:

- **Hide-on-screen-share is dead.** Apple documents `NSWindow.sharingType =
  .none` as "a legacy constant that macOS no longer uses … Don't use this value
  to hide or omit content from being captured" (checked 2026-09-05). Cut.
- **The redaction "demo face" is cut.** `.redacted(reason: .privacy)` only
  affects Text/Image; rings, share bars and chart bars are Shapes and keep
  drawing real percentages. Replacement if wanted: one names-only Bool.
- **Real defects in v0.2.0 that README contradicts:** the default `URLSession`
  disk cache holds bearer tokens and cookies ("keeps no tokens on disk" is
  false); `RailHairline`'s 20 Hz `TimelineView` ≈ 4.8 % CPU idle; the shipped
  DMG has `get-task-allow`; `ModelPricing` makes an undisclosed weekly
  openrouter.ai call (principle 3) and the demo card prints dollars from it;
  `UpdateChecker` can run a modal `NSAlert` from the background timer; the
  first notification after launch is dropped; 403 HTML reads as "sign-in
  expired". All are tier 1 block A/B items.
- **Platforms changed under the parsers (Apr–Aug 2026):** Copilot monthly
  plans bill AI credits in dollars plus session/weekly lanes (AIrail reads the
  legacy `quota_snapshots` shape); Cursor split included usage into two pools;
  Codex Plus regained a 5-hour window while Pro is exempt (missing window ≠
  0 %); consumer Gemini shut, replaced by Antigravity; OpenRouter has an
  Analytics API. "Read the 2026 meters" is tier 1 block B.
- **CodexBar** is at 69 providers with forecasting, widgets, 365-day history,
  multi-account, CLI/hooks, iCloud sync. README's comparison table is stale;
  replace it with a "why the edge" story. The notch is not a moat (6+ apps);
  the edge rail + per-display placement + ambient hairline is the unique
  surface. Biggest gap: private, un-notarized, not on Homebrew. macOS 15
  removed the Control-click "Open" bypass README step 1 describes.
- **Money:** do not charge $2 (Dodo's fixed fee eats a quarter of it) and do
  not charge monthly. Buy the Developer ID this week; ship v0.3.0 free, MIT,
  notarized, public, with Sponsors and a personal Homebrew tap; then a $12
  one-time soft licence via Dodo Payments (public licence endpoints, no
  secret) in the first post-launch release. Privacy and everything already
  shipped stay free. Details and fee table in `ROADMAP.md`.
- **v0.3.0 launch scope (my pick):** tier 1 blocks A + B + E plus the first
  three block C items (hairline-only island, Core Animation hairline, ambient
  headroom). v0.2.1 = the hardened-runtime fix alone, or hold it for v0.3.0.

## Don't build: recap card yet (2026-09-06)

- **Deferred, for the record; no code.** No "Share This Week…" until three
  things exist: an Apple Developer ID and a notarized, public release (a share
  card for an app nobody can download is a poster for a rumour, and with no
  verified identity behind the release there is nobody to answer a brand
  complaint about four marks on AIrail-branded pixels); the block B usage
  ledger, so the card covers a calendar week rather than the rolling 7-day
  sum the transcripts give today; and the consolidated menu the entry point
  hangs off. It is tier 2 `recap-card-redacted` in `ROADMAP.md`, the first
  Pro-labelled candidate. The "Next up" nicety below is now that gate.
- **Why not sooner:** the poster's headline would be the app's weakest number.
  `ModelPricing.estimate` prices a whole week at each model's list rate with
  guessed cache rates for unlisted ids; honest behind a `.help` tooltip that
  says "est.", a bare claim once it is a PNG on social media (principle 4).
  Screen Time, Battery and Activity Monitor have no share-as-image — Apple's
  cards live in Fitness and Music Replay, not in the utility register
  (principle 1). And a share pipeline is a second card view, a renderer, a
  share sheet and light/dark variants: platform-shaped (principle 5).
- **The `ImageRenderer` trap, so nobody pre-builds the wrong thing:**
  `ImageRenderer` (macOS 13+, `.scale`, `.nsImage`) renders pure SwiftUI
  only — text, images, shapes — and, per Apple's docs, draws a placeholder
  for AppKit-backed views. The HUD has two: the header's `Menu`
  (`OverlayView.header`, `.menuStyle(.button)`) and the chart's segmented
  `Picker` (`UsageChartSection`). Its `.ultraThinMaterial` (`OverlayView`,
  `GlassPanel`, `LogoMark`'s default disc) has nothing behind it offscreen,
  so the glass comes out flat grey. So the sketch "extract a ProviderCardView
  from `OverlayView.content` and render it" is wrong in practice. The card
  must be its own value-typed, material-free, control-free view — a solid
  paint, `LogoMark(onDark: true)` (already a solid disc), shapes and text —
  rendered with `ImageRenderer(scale: 2, isOpaque: true)` to an `NSImage` and
  offered through SwiftUI `ShareLink(item:preview:)` (macOS 13+), which
  wraps `NSSharingServicePicker` for free. Never an extraction of
  `OverlayView`. Nothing of the kind exists in the tree today (checked).
- **Share-sheet notes for then:** the app is `.accessory` and the HUD a
  `.nonactivatingPanel`, so in-process service sheets (Notes, Reminders) can
  land behind other windows unless `NSApp.activate` runs first; and
  `OverlayWindowController`'s global click monitor closes the HUD on any
  click in another app, so a hop to Messages dismisses it mid-flow — the
  entry point belongs in the consolidated menu, not on the card. The picker
  itself asks for nothing; chosen services may (Add to Photos → Photos TCC).
  To decide then: whether the API-equivalent estimate belongs on it at all.
- **By hand, Vincent:** nothing. `ROADMAP.md` box ticked. 69 tests green,
  unchanged; 5 live skipped.

## Don't build: the demo face (2026-09-06)

- **Cut, for the record; no code.** No privacy-redaction mode: no
  `AppSettings` key, no menu item, no `.redacted(reason: .privacy)`, no
  `.privacySensitive()` (none exist in the tree today either; checked). The
  collapsed surfaces already give a presenter what they want: the rail's marks
  and the notch show which tools are connected and a percent, the hover
  caption adds the plan name at most, and the plan pill, BY PROJECT names and
  the value line sit on the card, which opens only on a click. The account
  identity is in Settings › Accounts, not on any surface.
- **Why redaction can't do it:** SwiftUI redaction affects `Text` and `Image`
  only. The session ring (`OverlayView.sessionRing`, `Circle().trim`), the
  rail marks (`LogoMark`, the same trim), the BY MODEL / BY PROJECT share bars
  (`UsageChartSection.column`, `Capsule`) and the chart bars
  (`RoundedRectangle`) are Shapes and keep drawing the real percentages, so a
  "redacted" card is grey text blocks over live rings: it looks broken, not
  private. And macOS has no system trigger for an app's own windows (the
  system applies `.privacy` to WidgetKit content only), so it would have
  needed its own toggle regardless.
- **The companion switch is cut too.** `NSWindow.sharingType = .none` is
  public AppKit, no entitlement or prompt, and it does hide a window from
  ScreenCaptureKit and CGWindowList captures on macOS 14 through 15.3; from
  15.4 ScreenCaptureKit composites the whole framebuffer and ignores it
  (Apple DTS, forums thread 792152: "there are no public APIs for preventing
  screen capture"; only legacy `CGWindowListCreateImage` callers still honour
  it; `.readWrite` is deprecated in the 15 SDK). A labelled "hide from screen
  sharing" switch would silently fail in Zoom, Meet and QuickTime on the macOS
  most people run.
- **If it ever comes back:** decision 2's pick is one names-only Bool (email,
  plan, projects; rings stay real), which the tier-3 mirror-detection sliver
  could flip on its own; the narrowest version, if BY PROJECT names alone
  draw a complaint, is a single "Show project names" toggle under General.
  Either is added on demand, not before.
- **By hand, Vincent:** nothing. `ROADMAP.md` box ticked. 69 tests green,
  unchanged; 5 live skipped.

## Don't build: caps, forecasts, idle flag; fix the spend footer (2026-09-06)

- **Three cuts, for the record.** No AIrail-set soft caps: no cap is
  reachable through any read-only endpoint AIrail uses (Cursor's spend cap,
  Copilot's budgets, the Anthropic/OpenAI org limits all live behind their
  dashboards), so a cap set here would disagree with the platform's, and it
  would need per-account preferences and daily history that don't exist. No
  month-end bill projection: slope-fitting a month from a week is a guess
  wearing a dollar sign (principle 4); block B's pace item is arithmetic on
  server truth instead. No idle-subscription flag ("you haven't used Claude
  in 12 days"): a nag, not peripheral vision, and it needs the ledger anyway.
  `ROADMAP.md` lists all three under "Cut".
- **What was wrong:** the footer captioned every spend figure "SPEND (SEP)".
  OpenRouter's `usage` is all time, and its ring was that lifetime figure
  over a key limit that may reset daily, weekly or monthly.
- **Fix:** `UsageSnapshot.spendPeriod` (`SpendPeriod`: month, billingCycle,
  lifetime, keyLimit) names the window; the footer caption and its VoiceOver
  label switch on it ("SPEND (SEP)", "SPEND (THIS CYCLE)", "SPEND (ALL
  TIME)", "SPEND (KEY LIMIT)"). OpenRouter's ring is now
  `(limit − limit_remaining) / limit`, what OpenRouter itself counts, and the
  footer pairs a figure only with a cap measured over the same window: this
  UTC month (`usage_monthly`) for an open key or a monthly budget, the key's
  own budget when it resets on another clock or never, the lifetime total
  only when the answer has no monthly figure. Cursor tags its billing cycle;
  Claude usage credits and the two org cost reports stay month-to-date.
- **Money follows the locale:** `UsageFormatting.dollars`/`credits` use
  `.currency(code:).locale(locale)` — "$12.50" here, "US$12.50" on an en_GB
  Mac, "CN¥88.00" for a DeepSeek yuan balance. Tests pin en_US and en_GB.
  Dates and durations wait for block B's locale item.
- **By hand, Vincent:** nothing required. One live run with
  `TEST_RUNNER_AIRAIL_OPENROUTER_KEY` would confirm `usage_monthly` and
  `limit_reset` on a real key (the docs list both); a nicety, not a gate.
- 69 tests green (+2): the four OpenRouter key shapes, Cursor's tag, money
  in two locales and the four captions.

## Quiet the update check (2026-09-06)

- **What was wrong:** the release check ran once, at launch, and when it
  found something it put a modal `NSAlert` — `NSApp.activate` and all — over
  whatever you were doing; an app left running for a week never looked again.
- **Fix:** the menu item still gets its alert (it asked). The background path
  posts one notification per release version (`notifiedUpdateVersion`,
  remembered only once posted), category `update` with a **Download**
  button, silent, no activation; a click opens the release page and Download
  the DMG — only one served from github.com — in the browser, AIrail stays
  put. `AppDelegate` registers the category next to the delegate and routes
  the response by category. An hourly tolerant `Timer`
  (`UpdateChecker.startBackgroundChecks`) replaces the launch-only call; the
  request itself stays once a day (`lastUpdateCheck`). Each answer lands in
  `RailUIState.availableUpdate`, so the three menus read **Update to
  0.2.1…** until you have it. README's Releasing section says all this.
- **Permission:** the same question the usage alerts ask
  (`UsageNotifier.systemAuthorization`, now internal): never asked → the
  system prompt, once; refused → nothing, never an alert as the fallback.
  The menu relabel needs none of it.
- **By hand, Vincent:** nothing now. The private repo answers 404, so the
  quiet path stays silent until go-public; give the first real one a look
  (the banner, the Download button, the relabel).
- 67 tests green (+3): release parsing, the notification's links and where a
  response goes, the menu title. Timer and posting are untested, like the
  refresh timer.

## Notifications the Apple way (2026-09-06)

- **What was wrong:** `UsageNotifier` asked for permission at the first
  alert, remembered the answer from that one callback (so the first alert
  after launch was dropped while it was pending, and a permission flipped in
  System Settings never registered), kept "75 already said" in memory (a
  relaunch at 80% said it again), guessed the window reset from a percent
  drop on the next refresh, and a click did nothing. The toggle defaulted
  on before anyone had been asked.
- **Fix:** the prompt comes with the toggle (General pane, with an "Open
  System Settings…" row when macOS says no); `consider` reads
  `notificationSettings().authorizationStatus` at the moment of delivery and
  remembers a threshold only once delivered, so an alert macOS wasn't yet
  allowed to show comes through on the next refresh. Thresholds are kept in
  defaults per provider + reset time (`announcedThresholds`); a meter with
  no reset time starts over once it's 25 points under what was said. Past a
  threshold, one `UNTimeIntervalNotificationTrigger` at the provider's own
  reset time is handed to the system under `<id>.reset` and taken back on
  Remove Account, toggle-off and quit (`ProviderManager.stop()` from
  `applicationWillTerminate`), since the system would fire it for an app
  that isn't running. Every alert has `threadIdentifier` = provider (one
  group per account) and `userInfo.providerId`; `AppDelegate` is the
  `UNUserNotificationCenterDelegate` from the first line of launch — banners
  still show while AIrail is active, and a click expands the rail or island
  and opens that HUD (`OverlayWindowController.show(providerId:)`, never a
  toggle). The burn-rate samples restart when the reset time changes; a
  slope across a reset meant nothing. `notificationsEnabled` defaults off.
- **Left out:** the time-sensitive interruption level (needs the Developer
  ID's entitlement; would be silently downgraded now), notification actions.
- **By hand, Vincent:** the toggle is off on this build even if it was on
  before (v0.2.0 never wrote the default); flip it once, answer the prompt.
- 64 tests green (+3): once per window with the grouping fields, relaunch and
  permission, the scheduled reset and its withdrawal, window change vs. pace.

## One network path, allowlisted (2026-09-06)

- **What was wrong:** every request went through `URLSession.shared`, whose
  disk cache kept the usage bodies (api.anthropic.com, api.github.com,
  chatgpt.com, cursor.com) and whose cookie jar kept chatgpt.com's
  `__cf_bm`/`__oailb` cookies under `~/Library/Caches/com.codeandvin.airail`
  and `~/Library/HTTPStorages` — README's "keeps no tokens on disk" was
  false — and nothing stopped a redirect (or a typo) from carrying a bearer
  token to some other host.
- **Fix:** `HTTPClient.session` is one ephemeral session — `urlCache` nil,
  `httpCookieStorage` nil, cookies never set nor accepted, `User-Agent:
  AIrail`, waits for connectivity, 30 s resource timeout — with a
  `RedirectGuard` delegate that refuses any redirect off
  `HTTPClient.allowedHosts` (seven hosts, named in code and in README).
  `send` throws the new non-transient `ConnectionError.blockedHost` before a
  task exists for anything that isn't https to a listed host on the default
  port; a refused redirect surfaces as the same error naming where it
  pointed. `UpdateChecker` rides the same session through `HTTPClient.get`.
  At launch `HTTPClient.removeLegacyStores()` deletes v0.2.0's
  `Caches/<bundle id>` and `HTTPStorages/<bundle id>.binarycookies` (the
  Alt-Svc `httpstorages.sqlite` stays: no personal data in it) — every
  launch, a no-op once gone, so there is no migration flag to keep.
- **By hand, Vincent:** run `TEST_RUNNER_AIRAIL_LIVE=1 xcodebuild -scheme
  AIrail test` once on this build. Dropping the cookie jar is the one thing a
  Cloudflare-fronted host (chatgpt.com, cursor.com) could notice, and I could
  not touch the network from here; a Cursor or Codex read that starts
  answering "HTTP 403" is where to look.
- **Follow-ups:** the Privacy pane (block E) reads `HTTPClient.allowedHosts`
  for its "where it connects" list; the sleep/wake item (block B) reuses this
  session and its `waitsForConnectivity`; add `live.dodopayments.com` to the
  list only if the licence ships.
- 61 tests green (+4): session config, every endpoint allowed, off-list /
  http / port / subdomain refused before any task, scrub leaves Alt-Svc alone.

## Simplify: static price table (2026-09-06)

- **What was wrong:** `ModelPricing` fetched openrouter.ai's model catalogue
  weekly for every user at every launch — a network call README's "only
  network traffic is each connected tool's own usage check" line never
  disclosed — cached it in UserDefaults, and the demo card priced its made-up
  tokens in real dollars. The lookup also matched prefixes both ways, so a
  bare "gemini-3-pro" took the longest sibling's price; and the unit test
  "used the offline table" while actually reading the host app's live cache.
- **Fix:** the fetch, both cache keys and the `@MainActor` global are gone;
  `ModelPricing.table` is a shipped ~22-row table keyed by normalized id
  fragments ("opus-4.1", "opus", "gpt-5.2", "gpt-5", "gemini", …) matched at
  "-"/"."/end boundaries, longest key wins — a version with its own price
  beats its family row, Cursor's "cursor-grok-…" ids match mid-string, and
  "gpt" never fits "chatgpt-4o-latest". `estimate` prices the week's
  input/output/cache mix per model, each weighted by its share of the week's
  tokens (was: the dominant model's rate for everything); `TokenPrices.cost(of:)`
  is the reusable half for cost-by-model. The HUD shows the line only for a
  non-demo snapshot with `spend == nil` and `week.cost == 0` — a reported spend
  or Cursor's per-request cents beat an estimate of the same thing.
- **By hand, Vincent:** the prices are from memory as of 2026-09-06 and could
  not be checked against the vendors from here; check `ModelPricing.table`
  before cutting v0.3.0 (now a line in README › Releasing and the go-public
  checklist). The v0.2.0 install left `modelPricesCache`/`modelPricesCacheDate`
  in `defaults` for `com.codeandvin.airail`; harmless, delete if you like.
- 57 tests green (+2): apportioning, most-specific-row matching, table sanity.

## Single-flight, testable refresh (2026-09-06)

- **What was wrong:** `ProviderManager.refresh` had no in-flight guard, so
  the timer, the Refresh button and a wake-from-sleep could read the same
  account twice at once (for Claude, two Keychain reads), and a read that
  landed after Remove Account put the numbers straight back. None of it was
  testable without a signed-in Mac — providers, the notifier and `Date()`
  were baked in — and every `xcodebuild test` ran the host app's `start()`
  against live endpoints.
- **Fix:** `inflight: [String: Task]` per provider. A second `refresh` joins
  the running read; `force` skips the backoff window but never cancels (a
  cancelled `URLSession` throws, which read as a real failure and bumped the
  streak); `disconnect` cancels; the post-fetch write re-checks
  `!Task.isCancelled && isConnected` on the success *and* the error path.
  `refreshAll` maps the connected accounts (or the demo set), not all nine
  providers. `init(settings:providers:notifier:clock:)` with the real ones
  as defaults; `UsageNotifier.init(authorize:deliver:)` plus a
  `convenience init()` for Notification Center, so no test ever trips the
  system permission prompt. `AppDelegate` skips `start()`, the update check
  and the pricing fetch under `XCTestConfigurationFilePath`.
- **Tests:** `ProviderManagerTests.swift` — `FakeProvider` (scripted
  results, holdable reads, throws "cancelled" like URLSession), `TestClock`,
  `NotificationInbox`; ten cases covering join, cancel-on-disconnect, force
  vs. timer, 1→2→4 min backoff and Retry-After, stale vs. error, membership,
  connect's real read, thresholds once per window, projection through the
  clock. 55 green (+10); none touch the network.
- **Left alone, on purpose:** the first alert after launch can still be
  dropped while the permission callback is pending (notifications item);
  `KeychainReader`'s `Thread.sleep` stays — `SecItemCopyMatching` blocks that
  thread for the whole prompt anyway.

## Remove: v0.1 snapshot fields (2026-09-06)

- **Gone from `UsageSnapshot`:** `sessionUsed`/`sessionLimit` (nil at every
  builder, read nowhere), `weeklyHistory` + `historyDates` (all nine builders
  filled it from the same series that feeds `detail.days`, so the chart's
  fallback branch could never run) and `UsageStatus.outage` (emitted nowhere).
  Same pass: `JWT.expiry`, the scanner's `newestEventDate` (written, never
  read) and `CursorUsage.Report.onDemandEnabled` (parsed for one assertion;
  Cursor's on-demand units are undocumented, so nothing ever showed it).
- **`detail` is non-optional now** — `UsageDetail()` when a source has no
  breakdown — and `UsageChartSection` is `init(detail:color:sessionWindow:)`,
  drawing the 7-day sparkline from `detail.days` only. No behaviour change;
  36 lines in, 88 out.
- **Rule from here:** the ledger, level line and pace build on
  `detail.days: [UsageBucket]`; nobody revives a parallel `[Double]`. The
  used-elsewhere item re-adds the newest event as `UsageDetail.newestLocalEvent`.
- 45 tests green; six test sites moved to `detail.days`, none added.

## Hardened, attested builds (2026-09-06)

- **What was wrong:** `release.sh` let `xcodebuild build` do the signing, and
  Xcode injects `com.apple.security.get-task-allow` for any non-distribution
  identity (self-signed included), so the shipped 0.2.0 has `flags=0x0(none)`
  and any same-user process can attach a debugger. Confirmed with
  `codesign -dvv` on `/Applications/AIrail.app`.
- **Fix in `scripts/release.sh`:** the build is only ad-hoc signed now;
  PlistBuddy stamps `AIrailCommit` (`git describe --always --dirty`) into
  Info.plist; then one `codesign --force --options runtime --timestamp --sign
  "AIrail Dev"` with no `--entitlements` — a re-sign carries none over, so
  get-task-allow is gone (proved on an ad-hoc scratch binary). Three asserts
  fail the build: no get-task-allow, `flags=0x10000(runtime)`, a `Timestamp=`
  line. The timestamp is a public RFC 3161 request to Apple, no account needed;
  if it ever refuses, drop the flag and its assert together. pbxproj untouched,
  so Debug still attaches. Not run here (private key + TSA): the first
  `./scripts/release.sh` is the smoke test.
- **Settings › General** gained a "Version" row (`Models/BuildInfo.swift`):
  `0.2.0 (0a744d2)` on a release build, bare `0.2.0` from Xcode — the commit
  only when the plist key exists. Moves to the Privacy pane if that ships.
- **`.github/workflows/release.yml`** (draft, `workflow_dispatch` only):
  macos-15 (Xcode 16; macos-14 stopped at 15), p12 into a throwaway keychain,
  `release.sh`, `attest-build-provenance` guarded on `!repository.private`
  (GitHub only attests public repos), draft release via `gh`. At go-public:
  add the two secrets, switch the trigger to `push: tags: ['v*']`.
- **By hand, Vincent, when cutting v0.3.0 (decision 4: not before):**
  re-create "AIrail Dev" with 10-year validity — Keychain Access › Certificate
  Assistant › Create a Certificate…, Self Signed Root, Code Signing, "Let me
  override defaults", 3650 days; delete the 2027 one first so `--sign "AIrail
  Dev"` isn't ambiguous. One Claude Keychain re-prompt follows (new designated
  requirement); the timestamp keeps old signatures valid past 2027-09-02.
- 45 tests green (+1, `BuildInfo.label`).

## Where things stand (resume here)

- **Shipped in v0.2.0:** accounts (borrow each tool's existing sign-in,
  read-only) with live data for Claude, Codex (covers ChatGPT), Copilot,
  Cursor; `Other…` API-key platforms; the overlay card (rings, meters,
  24h/7-day chart, by-model/project, activity); Left/Right/Notch/Island
  placement with per-display choice; frosted-glass styling + one-motion reveal;
  the four insights (burn-rate, notifications, ambient rail colour,
  API-equivalent value priced live from OpenRouter); app icon; in-app update
  checker. 44 tests green.
- **Distribution:** repo **private**; `v0.2.0` is a **draft** GitHub release
  with the signed DMG attached. `./scripts/release.sh` builds the DMG (signed
  with the local "AIrail Dev" cert). Install = download DMG, drag, one-time
  right-click → Open.
- **The one external blocker:** no Apple Developer account ($99/yr). It gates
  notarization (→ no first-launch warning) and Sparkle (→ true one-click
  in-place updates). Everything else is done and free. When it's in hand:
  notarize in `release.sh`, add Sparkle, flip the repo public, publish the
  release — all drop-ins, documented below.

## Next up (when we resume)

- [ ] Verify the four **keyed platforms** (OpenRouter/DeepSeek/Anthropic API/
      OpenAI API) against real API keys — parsers are fixture-tested only.
- [ ] **Gemini** provider — find a dependable quota read.
- [ ] Go-public checklist: Apple Developer ID → notarize → Sparkle → repo
      public → publish `v0.2.0` (or cut `v0.3.0`). Every release: check
      `ModelPricing.table` against the vendors' price pages.
- [ ] Optional nicety floated but not built: per-account history for Copilot
      (no local feed; the block B usage ledger is the store it needs).
- [ ] **Recap card ("Share This Week…") — gated.** Not before an Apple
      Developer ID and a notarized, public release, the usage ledger (a
      calendar week, not a rolling sum) and the consolidated menu. Tier 2
      `recap-card-redacted` in `ROADMAP.md`; the `ImageRenderer` trap and the
      share-sheet notes are under "Don't build: recap card yet" above.

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
  tokens at the dominant model's price. **Live prices** now come from
  OpenRouter's public models API (`/api/v1/models`, no auth, current, with
  cache read/write), matched by a normalized model id, cached weekly in
  UserDefaults; a small built-in table is the offline/unmatched fallback.
  Verified live: the estimate for the current week jumped from a placeholder
  to a real figure. Labelled "est." in the UI.

## Claude Keychain hiccup handled (2026-09-03)

Morning error "Couldn't read the local data: An invalid record was encountered"
then a forced manual refresh. Cause: Claude is the only provider reading a
macOS Keychain item (others read files / shell out to `gh`), so only it is
exposed to the login Keychain locking after sleep and to Claude Code rotating
its credential — both make a read momentarily fail. That transient failure was
filed as a permanent `.unreadable`, blanking the account and requiring a manual
refresh. Fix: `KeychainReader` retries 3× (150 ms), and a persistent odd status
becomes `.temporarilyUnavailable` (transient) — the last good numbers stay as
`stale` and the next refresh recovers on its own. Prompt-related statuses
(auth/cancel/interaction) stay `.accessDenied` (transient, no retry, so the
dialog isn't hammered). The re-authorization prompt itself is inherent to
Claude Code recreating its Keychain item on rotation and can't be suppressed.

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
