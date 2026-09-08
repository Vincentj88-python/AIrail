# Changelog

## Unreleased

- **Settings › Rail › Automatically hide the rail.** Off, the edge rail stays open as the stack of marks and rings all day, Dock-style, floating over your windows rather than reserving space. Left and Right only; Top keeps its hover island.

## 0.3.0

The honest-numbers release: everything the card and the rail show is either a real read or labelled as an estimate, the surfaces cost nothing to keep on screen, and a Privacy pane lists exactly what AIrail touches.

### The rail and the island

- **Top** replaces Notch and Island as one position. On a display without a notch, idle is a hairline only, just under the centre of the menu bar; nothing floats over the bar or over full-screen video until you hover.
- The hairline **fills along its length** with your nearest limit, over a faint track, and its breath is now played by Core Animation: near-zero CPU, still under Reduce Motion, Low Power Mode or thermal pressure, paused while occluded or asleep.
- The island's idle caption reads the account nearest its limit, the one with room, and the next reset.
- At **100%** every caption and the ring centre count down to the reset instead of saying 100%, and a final alert names it.
- A small tick on each ring marks how far the window has elapsed.

### The card

- Every string follows your locale: 12/24-hour clock, day-month order, currency. Reset times under a day tick by themselves. Spans read "2h 40m".
- The ring carries an inner arc for time elapsed in the window and a "left" caption; the card says "12 pts above an even pace" from the provider's own numbers.
- A session figure that moves while this Mac's transcripts don't produces one observation line.
- A Screen Time-style header: the last 24 hours, or the daily average against last week, with a dashed average on the 7-day chart.
- Cost sits beside each model and project, Cursor's real cents plain and everything else an estimate at public API prices.
- Stale numbers expire at their own reset and the card says when the window ended.

### Accounts

- Copilot's credits-billed plans read as **AI credits** with GitHub's own dollar note; Cursor's pools carry their dashboard names; Claude's per-model weekly buckets appear as meters when populated.
- Copilot gets a day-by-day chart from levels AIrail samples once a day.
- Claude Code's hashed Keychain item name (`CLAUDE_CONFIG_DIR`) is found.
- Offline keeps the last numbers under a wifi note; wake triggers one read after a short settle.
- A moved endpoint is an honest "check for an update" error that keeps the last numbers, with a Report link.

### Trust

- One ephemeral, allowlisted network session: seven hosts, no cache, no cookie jar. The v0.2.0 cache that held bearer tokens is removed at launch.
- The pricing table is shipped, not fetched.
- Releases are signed with the hardened runtime, timestamped, with no debugger entitlement.
- **Settings › Privacy**: what AIrail reads, every host contacted since launch, what it keeps on disk, what this build is signed with, and Remove All Data.
- One menu everywhere, with About AIrail, Report a Problem and Save Diagnostics, all redacted; nothing is ever sent by itself.
- Notifications ask for permission only from the Settings toggle, open the account's card on tap, and the update check posts a notification instead of a modal.
- A per-account usage ledger under `~/Library/Application Support/AIrail` (daily totals, model ids, project folder names; never a token, key or email) restores the last numbers and the pace on relaunch.

### Under the hood

- One read per account at a time, cancelled cleanly on removal; injected providers, notifier and clock make the refresh loop testable. 44 tests became 99.
- Live tests can record redacted endpoint fixtures and catch drift.
- Launch flags `--expanded` and `--demo=<percent>` and `scripts/screenshots.sh` shoot the README captures from demo data.

## 0.2.0

Accounts that borrow each tool's existing sign-in read-only; live data for Claude, Codex, Copilot and Cursor; keyed platforms; the card with rings, meters, charts and breakdowns; Left, Right, Notch and Island placement; the first four insights; the in-app update checker.
