# codexCycle 产品规格

## Purpose

`codexCycle` is a personal, menu-bar-only macOS app that shows the remaining percentage in the main Codex five-hour or weekly quota window. The five-hour view is the first-use default, and the user can switch the preferred view from the menu. It has no Dock icon, main window, notifications, telemetry, updater, or login flow.

English is the first-use interface language. The user can switch between English and Simplified Chinese from the menu without restarting the app, and the app persists that selection.

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
- A Desktop Runtime is trusted only when the containing app has bundle identifier `com.openai.codex`, both the app and bundled executable pass macOS code-signature validation, and both are signed by OpenAI Team ID `2DC432GLL2`. Re-signed, modified, and unofficial desktop builds are rejected.
- Prefer a compatible independent Codex CLI. If none is available, try the current ChatGPT Desktop Runtime, followed by the legacy Codex App on a best-effort basis. Within a source tier, use the newest version that completes app-server initialization and supports `account/rateLimits/read`.
- Keep one private `codex app-server --stdio` child process alive for the app lifetime. Stop it when the app exits and restart it with delays of 1 second, 5 seconds, 30 seconds, then 5 minutes if it crashes.
- Implement only the required JSON-RPC subset: initialization, `initialized`, `account/rateLimits/read`, and `account/rateLimits/updated`. Unknown fields and unrelated notifications are ignored.
- A limit update notification triggers a full snapshot read instead of merging the sparse notification locally.
- Never read, copy, store, display, or log Codex credentials.
- If Codex is not logged in, show the unavailable state and instruct the user to log in through the corresponding Codex product separately; `codexCycle` does not open a terminal, desktop app, or browser.

## Quota windows and remaining calculation

- Read only the main `codex` metering bucket.
- Treat only `windowDurationMins == 300` as the five-hour window and only `windowDurationMins == 10080` as the weekly window. Either window may appear as the primary or secondary window.
- Never infer a window from its field position, name, or reset time. Ignore credits, plan type, reset credits, other durations, and other model or feature buckets.
- Parse the five-hour and weekly windows independently. If one is missing, keep the other as fresh, usable data; if both are missing, the usage state is unavailable. Never substitute a different bucket or duration.
- Displayed remaining percentage is `floor(100 - usedPercent)`, clamped to `0...100`.
- The center of the indicator contains the integer only, with no percent sign.
- A valid percentage remains usable if `resetsAt` is absent, but its reset countdown is `—` and it is not persisted across app restarts.

## Preferred and current view

- On first use, the preferred quota view is five-hour. Persist every explicit user selection and restore it on the next launch.
- The current view normally equals the preferred view. If the preferred window is unavailable and the other window is available, temporarily show the available window without overwriting the preference.
- Fallback is symmetric: five-hour may fall back to weekly, and weekly may fall back to five-hour. When the preferred window becomes available again, switch back automatically.
- An unavailable menu option remains selectable. Selecting it changes the preference even though the current view must continue to fall back until data becomes available.
- Selecting either quota view updates the indicator immediately using existing data, marks the menu as refreshing, persists the preference, and immediately requests a Runtime refresh.

## Refresh behavior

- Refresh immediately on launch and after the Mac wakes.
- Poll every five minutes while the Mac is awake; do not wake a sleeping Mac.
- Refresh immediately when the app-server sends a rate-limit update.
- Manual refresh is available from the menu and restarts the five-minute interval after success.
- Selecting a quota view also refreshes immediately. Overlapping selection and other refresh triggers are coalesced.
- A refresh has a 15-second timeout.
- Coalesce overlapping launch, timer, wake, manual, and event-triggered refreshes into one request.
- Ordinary failures wait for the next scheduled or manual attempt. A child-process crash uses the restart backoff above.
- While refreshing, keep a valid existing reading unchanged. With no reading, show a gray `—`. Disable repeated manual refresh until the request completes.
- Expire each window exactly at its own reset boundary. If the expired window was the current view, refresh immediately; if it was hidden, only invalidate its reading and do not trigger a Runtime refresh. Switching views or falling back changes which boundary qualifies for immediate refresh.
- A successful snapshot that omits one window immediately marks only that window unavailable and invalidates its old reading. This partial-availability state is not a refresh failure and does not gray the available window.

## Indicator

- Use a fixed approximately `22 × 22 pt` circular indicator.
- The center is a transparent glass face containing a centered monospaced integer.
- The outside is a roughly `2 pt` remaining-progress ring, starting at 12 o'clock and growing clockwise.
- The remaining arc uses a fixed multicolor scale: red at 0, yellow at 20, green at 50, and green through 100. The consumed track is low-contrast transparent glass.
- On macOS 26 and later, use native Liquid Glass. On macOS 13–15, approximate it with translucent material and a highlight stroke.
- Respect Reduce Transparency and Increase Contrast by falling back to a high-contrast solid face.
- A stale reading keeps its number but turns the ring gray. With no successful reading, show a gray `—`.
- The indicator always represents the current view and does not add a `5h`, weekly, or other window badge; the menu identifies the window.
- Do not add custom VoiceOver or other accessibility wording.
- The static Finder app icon uses the same glass face and multicolor ring with `100` in the center.

## Menu

The app has no main window. Clicking the indicator opens the detail menu in the persisted interface language. On first use, the English menu appears. When both windows are available and five-hour is preferred:

```text
Display Quota
✓ 5-hour remaining   67%
  Weekly remaining  42%
Resets in            3 hours 18 minutes
Last updated         3 minutes ago
────────────
Language
✓ English
  简体中文
────────────
Refresh Now
────────────
Quit codexCycle
```

During fallback, the checkmark still identifies the persisted preference and a separate row identifies the effective current view:

```text
Display Quota
✓ 5-hour remaining   —
  Weekly remaining  42%
Current view         Weekly remaining (5-hour data unavailable)
Resets in            2 days 3 hours
Last updated         3 minutes ago
```

- The five-hour and weekly rows are clickable even when their data is unavailable. Other information rows are disabled; action rows are clickable.
- The checkmark identifies the preferred view, not necessarily the current view. Show the localized current-view explanation only while fallback makes the two views differ.
- Both menu readings include `%`; an unavailable reading is `—`. The center indicator omits `%`.
- The reset countdown and status colors always correspond to the current view and change immediately when the current view changes.
- The reset countdown uses at most two units and no seconds: `2 days 3 hours`, `4 hours 18 minutes`, or `less than 1 minute` in English, with equivalent Simplified Chinese text.
- The menu recalculates relative times at least once per minute while the app runs.
- A missing non-current window is shown only on its own row. A missing preferred window is also explained by the fallback row; neither case is a global error.
- Errors add one short localized reason when both windows are unavailable or the request fails: Codex Runtime not found, incompatible Codex Runtime, not logged in, both supported limits missing, network failure, or Codex service unavailable.
- The Language rows remain available in both localizations. Switching language updates the open menu immediately and persists the choice; first use defaults to English.
- If login launch is disabled, show that state and provide a localized action that opens Login Items Settings.
- The localized `Quit codexCycle` action stops the current process but leaves launch-at-login registered.

## Cached state and failure behavior

- Store only the preferred view, interface language, the last successful reading for each supported window, verified Runtime path and version, and login-registration attempt in the app's `UserDefaults`. Each reading contains its percentage, reset timestamp, and fetch timestamp.
- Persist a window reading only when it has a reset timestamp.
- On launch, restore each non-expired reading as gray and stale until a live refresh succeeds, then derive the current view from the restored preference and available readings.
- Expire and discard each cached window independently at its own reset timestamp. If the current window expires while the other remains usable, apply the normal fallback rule.
- A total refresh failure retains each non-expired reading as gray stale data and shows the last successful update plus a short reason.
- A successful partial snapshot clears the omitted window's cached reading and leaves the returned window fresh; it does not reuse the omitted window as stale data.
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

- Unit tests cover exact five-hour and weekly window selection in either field, remaining calculation, preferred/current view derivation, symmetric fallback, selection persistence, English-default and Simplified-Chinese presentation, gradient bands, countdown formatting, independent cache expiration, partial availability, and error classification.
- A fake JSONL app-server process covers initialization, timeout, process exit, sparse-update handling, and full-snapshot refresh without a real account.
- Real acceptance verifies the default English interface, live switching to persisted Simplified Chinese, default five-hour view, selectable and persisted weekly view, immediate refresh after selection, fallback explanation, automatic recovery to the preferred view, current-view reset refresh, indicator, menu, manual and periodic refresh, wake refresh, login launch, real quota percentages, independent cache and stale states, independent CLI discovery, current ChatGPT Desktop-only discovery, source priority, and error states.
- Reading limits must not start model work or consume model usage.
- Idle operation must not continuously consume CPU.

## Primary references

- [Codex app-server](https://developers.openai.com/codex/app-server)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [Apple materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
