# codexCycle 产品规格

## Purpose

`codexCycle` is a personal, menu-bar-only macOS app that shows the remaining percentages in the main Codex five-hour and weekly quota windows. The status indicator remains weekly; the detail menu shows both windows. It has no Dock icon, main window, quota selector, notifications, telemetry, updater, or login flow.

The interface follows the language selected by macOS. English and Simplified Chinese are supported, with English as the fallback for other system languages. The app has no independent language setting.

## Supported environment

- Personal use on the current Apple Silicon Mac.
- App name: `codexCycle`.
- Bundle identifier: `com.fxl.codexCycle`.
- Native Swift and AppKit, arm64 only.
- Deployment target: macOS 13; acceptance testing targets macOS 26.5.2.
- Standard Xcode project with app and test targets and no third-party packages.
- The app runs outside App Sandbox and is signed locally for installation at `/Applications/codexCycle.app`.

## Usage data

- The sole data source is a compatible, locally installed and authenticated Codex Runtime.
- A Codex Runtime may come from an independently installed Codex CLI or from the Codex experience in the current ChatGPT desktop app. The pre-merge standalone Codex App is best-effort only and is not part of the formal compatibility promise.
- The app discovers independent Codex CLI executables through the process `PATH`, common package-manager locations, and Spotlight metadata search, and discovers the runtime bundled with supported desktop apps.
- Before execution, candidates must resolve to a local executable owned by the current user or root. The executable must not be group- or world-writable, ancestor directories must not be world-writable, and native executables must pass code-signature integrity validation. A group-writable Homebrew ancestor is allowed only when it is owned by the current user.
- An unsigned independent script launcher is accepted only when it uses the official npm-compatible `#!/usr/bin/env node` shebang. Its launcher directory and retained `PATH` directories must pass local ownership and permission validation, and the resolved `node` interpreter must be a trusted local regular executable. Other shebang forms and interpreters from unsafe `PATH` entries are rejected.
- A Desktop Runtime is trusted only when the containing app has bundle identifier `com.openai.codex`, both the app and bundled executable pass macOS code-signature validation, and both are signed by OpenAI Team ID `2DC432GLL2`. Re-signed, modified, and unofficial desktop builds are rejected.
- Prefer a compatible independent Codex CLI. If none is available, try the current ChatGPT Desktop Runtime, followed by the legacy Codex App on a best-effort basis. Within a source tier, use the newest version that completes app-server initialization and supports `account/rateLimits/read`.
- Keep one private `codex app-server --stdio` child process alive for the app lifetime. Stop it when the app exits and restart it with delays of 1 second, 5 seconds, 30 seconds, then 5 minutes if it crashes.
- Implement only the required JSON-RPC subset: initialization, `initialized`, `account/rateLimits/read`, and `account/rateLimits/updated`. Unknown fields and unrelated notifications are ignored.
- A limit update notification triggers a full snapshot read instead of merging the sparse notification locally.
- Never read, copy, store, display, or log Codex credentials.
- If Codex is not logged in, show the unavailable state and instruct the user to log in through the corresponding Codex product separately; `codexCycle` does not open a terminal, desktop app, or browser.

## Supported quota windows and remaining calculation

- Read only the main `codex` metering bucket.
- Treat only `windowDurationMins == 300` as the five-hour window and `windowDurationMins == 10080` as the weekly window. Either may appear as the primary or secondary window.
- Never infer a window from its field position, name, or reset time. Ignore credits, plan type, reset credits, other durations, and other model or feature buckets.
- The two supported windows are independently optional. Never substitute one window for the other. If neither is present, the usage state is unavailable.
- Displayed remaining percentage is `floor(100 - usedPercent)`, clamped to `0...100`.
- The center of the indicator contains the integer only, with no percent sign.
- A valid percentage remains usable if `resetsAt` is absent, but its reset countdown is `—` and it is not persisted across app restarts.

## Refresh behavior

- Refresh immediately on launch and after the Mac wakes.
- Poll every five minutes while the Mac is awake; do not wake a sleeping Mac.
- Refresh immediately when the app-server sends a rate-limit update.
- Manual refresh is available from the menu and restarts the five-minute interval after success.
- A refresh has a 15-second timeout.
- Coalesce overlapping launch, timer, wake, manual, and event-triggered refreshes into one request.
- Ordinary failures wait for the next scheduled or manual attempt. A child-process crash uses the restart backoff above.
- While refreshing, keep a valid existing reading unchanged. With no reading, show a gray `—`. Disable repeated manual refresh until the request completes.
- Expire each reading exactly at its own reset boundary and refresh immediately while retaining the other valid window.
- A successful response immediately invalidates old readings for any supported window it omits. This is not a transport failure and must not preserve stale data.
- At 7:00 AM in the current system time zone, run one minimal Codex request and then refresh quota data. Persist the attempt date so restarts and wakes do not duplicate the request on the same calendar day.
- If the app is not running or the Mac is asleep at 7:00 AM, perform the missed request once after the next launch or wake that same day.
- Run the daily request through the selected validated Runtime as `codex --ask-for-approval never exec --ephemeral --ignore-user-config --sandbox read-only --skip-git-repo-check`. The prompt requires a one-word response without tools or file inspection. Suppress process input and output and stop it after 90 seconds.

## Indicator

- Use a fixed approximately `22 × 22 pt` circular indicator.
- The center is a transparent glass face containing a centered monospaced integer.
- The outside is a roughly `2 pt` remaining-progress ring, starting at 12 o'clock and growing clockwise.
- The remaining arc uses a fixed multicolor scale: red at 0, yellow at 20, green at 50, and green through 100. The consumed track is low-contrast transparent glass.
- On macOS 26 and later, use native Liquid Glass. On macOS 13–15, approximate it with translucent material and a highlight stroke.
- Respect Reduce Transparency and Increase Contrast by falling back to a high-contrast solid face.
- A stale reading keeps its number but turns the ring gray. With no successful reading, show a gray `—`.
- The indicator always represents the weekly quota and does not add a weekly badge; the menu identifies the reading.
- Do not add custom VoiceOver or other accessibility wording.
- The static Finder app icon uses the same glass face and multicolor ring with `100` in the center.

## Menu

The app has no main window. Clicking the indicator opens the detail menu in the interface language selected by macOS. In English, the menu appears:

```text
5-hour remaining      75%
5-hour resets in      3 hours 18 minutes
Weekly remaining      42%
Weekly resets in      2 days 3 hours
Last updated          3 minutes ago
────────────
Refresh Now
────────────
Quit codexCycle
```

When both windows are unavailable, the menu retains the same shape:

```text
5-hour remaining    —
5-hour resets in    —
Weekly remaining    —
Weekly resets in    —
Last updated        —
Reason              5-hour and weekly quotas unavailable
```

- Both quota rows are read-only, include `%` when available, and show `—` otherwise. The center indicator continues to show the weekly reading and omits `%`.
- Each reset countdown corresponds to its own window. Status-indicator colors always correspond to the weekly reading.
- The reset countdown uses at most two units and no seconds: `2 days 3 hours`, `4 hours 18 minutes`, or `less than 1 minute` in English, with equivalent Simplified Chinese text.
- The menu recalculates relative times at least once per minute while the app runs.
- Errors add one short localized reason when both supported windows are unavailable or the request fails: Codex Runtime not found, incompatible Codex Runtime, not logged in, supported quotas unavailable, network failure, or Codex service unavailable.
- The menu and read-only diagnostics use the localization selected by macOS. The app does not override that choice or store a language preference.
- If login launch is disabled, show that state and provide a localized action that opens Login Items Settings.
- The localized `Quit codexCycle` action stops the current process but leaves launch-at-login registered.

## Cached state and failure behavior

- Store only the last successful five-hour and weekly readings, the last daily-request attempt date, verified Runtime path and version, and login-registration attempt in the app's `UserDefaults`. Each reading contains its percentage, reset timestamp, and fetch timestamp.
- Remove the obsolete `display.language` preference during upgrade so an earlier in-app choice cannot override the system-selected localization.
- Persist a reading only when it has a reset timestamp.
- On launch, restore non-expired readings as gray and stale until a live refresh succeeds.
- Expire and discard each cached reading at its own reset timestamp, then refresh immediately.
- A total refresh failure retains a non-expired reading as gray stale data and shows the last successful update plus a short reason.
- A successful response without a previously cached supported window clears that window; it does not reuse it as stale data.
- During upgrade, retain valid `usage.fiveHour.*` and `usage.weekly.*` caches, migrate legacy weekly data, and remove the obsolete preferred-view key.
- Detailed errors use macOS unified logging. Logs exclude tokens, account information, credentials, and full protocol payloads.

## Launch, privacy, and lifecycle

- Register the main app with `SMAppService.mainApp` so it launches on login.
- Respect a user-disabled login item. Do not repeatedly re-register it; show an action that opens the system Login Items settings.
- Do not collect analytics, telemetry, or crash reports.
- `codexCycle` performs no direct external network requests; Codex service access remains owned by the selected Codex Runtime.
- Prevent duplicate running instances.

## Build and repository

- Keep the public GitHub repository on `main` and publish versioned releases
  with an annotated tag and an arm64 DMG asset.
- `make build` builds the Debug app.
- `make test` runs automated tests.
- `make install` builds Release and installs `/Applications/codexCycle.app`.
- `make uninstall` unregisters login launch and removes the installed app while preserving Preferences.
- `make purge` performs uninstall and deletes `com.fxl.codexCycle` Preferences.
- The app has no self-updater.

## Verification

- Unit tests cover exact five-hour and weekly-window selection in either field, partial availability, remaining calculation, daily 7:00 scheduling and same-day deduplication, safe ephemeral exec arguments, system-selected localization with English and Simplified-Chinese resources, gradient bands, countdown formatting, independent cache expiration and migration, and error classification.
- A fake JSONL app-server process covers initialization, timeout, process exit, sparse-update handling, and full-snapshot refresh without a real account.
- Real acceptance verifies that the interface follows the macOS language without an in-app selector, the weekly indicator and dual-window menu, reset refresh, manual and periodic refresh, wake refresh, daily Codex request, login launch, real quota percentages, cache and stale states, independent CLI discovery, current ChatGPT Desktop-only discovery, source priority, and error states.
- Reading limits must not start model work or consume model usage. Only the explicit daily 7:00 refresh request starts a minimal Codex turn and consumes a small amount of the user's quota.
- Idle operation must not continuously consume CPU.

## Primary references

- [Codex app-server](https://developers.openai.com/codex/app-server)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [Apple materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
