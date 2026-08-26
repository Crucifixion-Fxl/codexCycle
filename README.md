# codexCycle

**English** | [简体中文](README.zh-CN.md)

`codexCycle` is a lightweight macOS menu-bar app that keeps your five-hour and
weekly Codex quotas visible without opening another window. It refreshes
automatically and uses your existing local Codex authentication.

<p align="center">
  <img src="docs/images/codexcycle-status-item.png" width="100" alt="codexCycle menu-bar indicator showing 85 percent remaining">
</p>

## What it shows

- The number in the menu bar is the five-hour remaining percentage. The center
  omits the `%` sign to stay readable at menu-bar size.
- The remaining arc follows a fixed red → yellow → green scale: red at `0`,
  yellow at `20`, and green from `50` through `100`.
- Clicking the indicator opens the five-hour and weekly readings, their reset
  countdowns, the last update time, Refresh Now, and Request Now.
- The interface follows the language selected by macOS by default. The menu can
  switch explicitly between Follow System, English, and Simplified Chinese.

## Display logic

- Only the main `codex` bucket's exact five-hour and seven-day windows are shown.
  Other windows are ignored rather than substituted.
- Remaining quota is `floor(100 - usedPercent)`, clamped to `0...100`.
- A failed refresh keeps a valid cached number but turns the ring gray. A reading
  expires at its reset boundary; no valid reading is shown as `—`.
- Reset time is relative, uses at most two units, and never displays seconds.
- Data refreshes on launch, every five minutes, after wake, after a quota update,
  at either reset boundary, and on manual refresh.
- At 7:00 AM local time each day, the app makes one minimal, ephemeral, read-only
  Codex request to start or roll the five-hour window, then reads the quotas
  again. A sleeping or closed Mac catches up once after the next wake or launch.
- **Request Now** runs the same safe request on demand and refreshes the quota
  readings when it completes.

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- An installed and authenticated Codex Runtime:
  - an independent Codex CLI, or
  - Codex in the current ChatGPT desktop app

## Install

Download the latest arm64 DMG from
[GitHub Releases](https://github.com/Crucifixion-Fxl/codexCycle/releases/latest),
open it, and drag `codexCycle.app` into `Applications`.

Public builds currently use ad hoc signing and are not notarized. On first
launch, macOS may require approval in **System Settings → Privacy & Security →
Open Anyway**. Only install releases from this repository.

## Build from source

```sh
make test       # Run the test suite
make install    # Build, install to /Applications, and launch
```

Additional targets:

```sh
make build      # Debug build
make release    # Release build
make dmg        # Create dist/codexCycle-<version>-arm64.dmg
make uninstall  # Remove the app and preserve preferences
make purge      # Remove the app and its preferences
```

## Data and privacy

`codexCycle` reads `account/rateLimits/read` from a local
`codex app-server --stdio` process. Daily and manually requested quota-refresh
turns run through the validated local Runtime as ephemeral `codex exec` sessions
with a read-only sandbox, tools disabled by instruction, and user configuration
ignored. The app does not read or store credentials, make direct network
requests, collect analytics, or send telemetry. Runtime executables are
validated before launch.

For implementation details, see the [product specification](docs/product-spec.md)
and the [runtime](docs/adr/0003-support-independent-and-desktop-codex-runtimes.md)
and [sandbox](docs/adr/0002-run-outside-the-app-sandbox.md) decisions.

## Troubleshooting

- **Codex Runtime not found:** install Codex CLI, or install and sign in to the
  current ChatGPT desktop app.
- **Codex Runtime incompatible:** update Codex CLI or ChatGPT, then choose
  **Refresh Now**.
- **Codex is not signed in:** sign in through the corresponding Codex product.
- **Launch at Login Disabled:** open Login Items Settings from the app menu and
  allow `codexCycle`.

Read-only diagnostics:

```sh
/Applications/codexCycle.app/Contents/MacOS/codexCycle --diagnose
```
