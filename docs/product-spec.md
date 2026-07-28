# codexCycle MVP

## Purpose

`codexCycle` is a personal, menu-bar-only macOS app that shows the remaining percentage in the main Codex weekly quota window. It has no Dock icon, main window, notifications, telemetry, updater, or login flow.

## Supported environment

- Personal use on the current Apple Silicon Mac.
- App name: `codexCycle`.
- Bundle identifier: `com.fxl.codexCycle`.
- Native Swift and AppKit, arm64 only.
- Deployment target: macOS 13; acceptance testing targets macOS 26.5.2.
- Standard Xcode project with app and test targets and no third-party packages.
- The app runs outside App Sandbox and is signed locally for installation at `/Applications/codexCycle.app`.

## Usage data

- The sole data source is a compatible, locally installed and authenticated Codex CLI.
- The app discovers Codex executables through the process `PATH`, common package-manager locations, and Spotlight metadata search.
- Before execution, candidates must resolve to a local executable owned by the current user or root. The executable must not be group- or world-writable, ancestor directories must not be world-writable, and native executables must pass code-signature integrity validation. A group-writable Homebrew ancestor is allowed only when it is owned by the current user.
- If multiple candidates remain, use the newest version that completes app-server initialization and supports `account/rateLimits/read`.
- Keep one private `codex app-server --stdio` child process alive for the app lifetime. Stop it when the app exits and restart it with delays of 1 second, 5 seconds, 30 seconds, then 5 minutes if it crashes.
- Implement only the required JSON-RPC subset: initialization, `initialized`, `account/rateLimits/read`, and `account/rateLimits/updated`. Unknown fields and unrelated notifications are ignored.
- A limit update notification triggers a full snapshot read instead of merging the sparse notification locally.
- Never read, copy, store, display, or log Codex credentials.
- If Codex is not logged in, show the unavailable state and instruct the user to log in through Codex separately; `codexCycle` does not open a terminal or browser.

## Weekly remaining calculation

- Read only the main `codex` metering bucket.
- Select only a window whose `windowDurationMins` is exactly `10080`.
- Ignore credits, plan type, reset credits, five-hour limits, and other model or feature buckets.
- If no exact main weekly window exists, the refresh fails; no other metric is substituted.
- Displayed remaining percentage is `floor(100 - usedPercent)`, clamped to `0...100`.
- The center of the indicator contains the integer only, with no percent sign.
- A valid weekly percentage remains usable if `resetsAt` is absent, but its reset countdown is `—` and it is not persisted across app restarts.

## Refresh behavior

- Refresh immediately on launch and after the Mac wakes.
- Poll every five minutes while the Mac is awake; do not wake a sleeping Mac.
- Refresh immediately when the app-server sends a rate-limit update.
- Manual refresh is available from the menu and restarts the five-minute interval after success.
- A refresh has a 15-second timeout.
- Coalesce overlapping launch, timer, wake, manual, and event-triggered refreshes into one request.
- Ordinary failures wait for the next scheduled or manual attempt. A child-process crash uses the restart backoff above.
- While refreshing, keep a valid existing reading unchanged. With no reading, show a gray `—`. Disable repeated manual refresh until the request completes.
- When the reset countdown reaches zero, refresh immediately.

## Indicator

- Use a fixed approximately `22 × 22 pt` circular indicator.
- The center is a transparent glass face containing a centered monospaced integer.
- The outside is a roughly `2 pt` remaining-progress ring, starting at 12 o'clock and growing clockwise.
- The remaining arc uses a fixed multicolor scale: red at 0, yellow at 20, green at 50, and green through 100. The consumed track is low-contrast transparent glass.
- On macOS 26 and later, use native Liquid Glass. On macOS 13–15, approximate it with translucent material and a highlight stroke.
- Respect Reduce Transparency and Increase Contrast by falling back to a high-contrast solid face.
- A stale reading keeps its number but turns the ring gray. With no successful reading, show a gray `—`.
- Do not add custom VoiceOver or other accessibility wording.
- The static Finder app icon uses the same glass face and multicolor ring with `100` in the center.

## Menu

The app has no main window. Clicking the indicator opens a Simplified Chinese menu:

```text
周余量        67%
重置倒计时    2 天 3 小时
最后更新      3 分钟前
────────────
立即刷新
────────────
退出 codexCycle
```

- Information rows are disabled; action rows are clickable.
- The center indicator omits `%`, while the menu includes it.
- The reset countdown uses at most two units and no seconds: `2 天 3 小时`, `4 小时 18 分钟`, or `不足 1 分钟`.
- The menu recalculates relative times at least once per minute while the app runs.
- Errors add one short Chinese reason: CLI not found, incompatible CLI, not logged in, weekly limit missing, network failure, or Codex service unavailable.
- If login launch is disabled, show that state and provide `打开登录项设置…`.
- `退出 codexCycle` stops the current process but leaves launch-at-login registered.

## Cached state and failure behavior

- Store only the last successful percentage, reset timestamp, fetch timestamp, verified CLI path and version, and login-registration attempt in the app's `UserDefaults`.
- Persist a reading only when it has a reset timestamp.
- On launch, show a persisted reading as gray and stale until a live refresh succeeds.
- If the cached reset timestamp has passed, discard the reading and show `—`.
- A failed refresh retains the last reading as gray stale data and shows the last successful update plus a short reason.
- Detailed errors use macOS unified logging. Logs exclude tokens, account information, credentials, and full protocol payloads.

## Launch, privacy, and lifecycle

- Register the main app with `SMAppService.mainApp` so it launches on login.
- Respect a user-disabled login item. Do not repeatedly re-register it; show an action that opens the system Login Items settings.
- Do not collect analytics, telemetry, or crash reports.
- `codexCycle` performs no direct external network requests; Codex service access remains owned by the Codex CLI.
- Prevent duplicate running instances.

## Build and repository

- Initialize a local Git repository on `main`; do not configure or push a remote.
- `make build` builds the Debug app.
- `make test` runs automated tests.
- `make install` builds Release and installs `/Applications/codexCycle.app`.
- `make uninstall` unregisters login launch and removes the installed app while preserving Preferences.
- `make purge` performs uninstall and deletes `com.fxl.codexCycle` Preferences.
- The app has no self-updater.

## Verification

- Unit tests cover weekly-window selection, remaining calculation, gradient bands, countdown formatting, cache expiration, and error classification.
- A fake JSONL app-server process covers initialization, timeout, process exit, sparse-update handling, and full-snapshot refresh without a real account.
- Real acceptance verifies the indicator, menu, manual and periodic refresh, wake refresh, login launch, real weekly percentage, cache and stale states, CLI discovery, and error states.
- Reading limits must not start model work or consume model usage.
- Idle operation must not continuously consume CPU.

## Primary references

- [Codex app-server](https://developers.openai.com/codex/app-server)
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [Apple materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
