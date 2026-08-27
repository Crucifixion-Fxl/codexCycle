<p align="center">
  <img src="docs/images/codexcycle-status-item.png" width="96" alt="codexCycle menu-bar indicator">
</p>

<h1 align="center">codexCycle</h1>

<p align="center">
  A native macOS menu-bar app for keeping Codex five-hour and weekly quotas in view.
</p>

<p align="center">
  <a href="README.md"><strong>English</strong></a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/Crucifixion-Fxl/codexCycle/releases/latest"><img src="https://img.shields.io/github/v/release/Crucifixion-Fxl/codexCycle?display_name=tag" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon arm64">
  <img src="https://img.shields.io/badge/Swift-AppKit-F05138?logo=swift&logoColor=white" alt="Swift and AppKit">
</p>

<p align="center">
  <a href="https://github.com/Crucifixion-Fxl/codexCycle/releases/latest"><strong>Download the latest DMG</strong></a>
</p>

<p align="center">
  <img src="docs/images/codexcycle-detail-panel.png" width="360" alt="codexCycle detail panel showing five-hour and weekly quota information">
</p>

## Highlights

- Shows the main Codex five-hour and seven-day quota windows in one compact panel.
- Keeps the most relevant remaining percentage visible in the macOS menu bar.
- Turns the selected quota into an animated water level while keeping the exact
  percentage visible.
- Refreshes after launch, wake, quota updates, reset boundaries, and every five minutes.
- Runs a minimal daily Codex request at 7:00 AM to start or roll the five-hour window.
- Includes Refresh and Request actions without opening a terminal or browser.
- Supports Follow System, English, and Simplified Chinese interface modes.
- Controls Launch at Login directly from the panel with an in-app switch.
- Stores no credentials and sends no analytics or telemetry.

## Display behavior

| Available quota windows | Menu-bar indicator | Main panel reading | Secondary reading |
| --- | --- | --- | --- |
| Five-hour and weekly | Five-hour | Five-hour | Weekly |
| Weekly only | Weekly | Weekly | Five-hour unavailable |
| Five-hour only | Five-hour | Five-hour | Weekly unavailable |
| Neither | Unavailable | Unavailable | Unavailable |

Remaining quota is calculated as `floor(100 - usedPercent)` and clamped to
`0...100`. Reset countdowns use relative time with at most two units and no
seconds. A valid cached reading remains visible in gray after an ordinary
refresh failure and expires at its own reset boundary.

The gauge's animated water height matches the remaining quota percentage while
the number and outside ring remain visible. The color scale is red at `0`, yellow
at `20`, and green from `50` through `100`. Reduce Motion freezes the water.

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- One authenticated Codex Runtime
  - an independent Codex CLI
  - Codex in the current ChatGPT desktop app

## Install

1. Download the latest arm64 DMG from [GitHub Releases](https://github.com/Crucifixion-Fxl/codexCycle/releases/latest).
2. Open the DMG.
3. Drag `codexCycle.app` into `Applications`.
4. Launch `codexCycle` and use the menu-bar indicator.

Public builds use ad hoc signing and are not notarized. macOS may ask for a
first-launch confirmation under **System Settings → Privacy & Security → Open
Anyway**. Install releases only from this repository.

## Everyday use

- Click the menu-bar indicator to open or close the detail panel.
- Use **Refresh** to read the latest quota state.
- Use **Request** to run one minimal Codex turn and refresh both windows.
- Use the language control to follow macOS or select English or Simplified Chinese.
- Use **Launch at Login** to register or unregister the app directly.
- Use **Quit codexCycle** or `⌘ Q` to stop the current process.

The scheduled 7:00 AM request and the explicit Request action each consume a
small amount of Codex quota. Reading the current limits does not start model
work.

## Runtime and privacy

`codexCycle` discovers a compatible local Runtime and communicates with
`codex app-server --stdio`. It reads `account/rateLimits/read` and listens for
rate-limit update notifications. The app validates Runtime ownership,
permissions, executable shape, and code signatures before launch.

The app does not

- read, copy, store, display, or log Codex credentials
- make direct network requests to the Codex service
- collect analytics, telemetry, or crash reports
- include a login flow or self-updater

Daily and manually requested turns run as ephemeral `codex exec` sessions with
a read-only sandbox, ignored user configuration, and a 90-second timeout.

## Build from source

The project uses Xcode, Swift, and AppKit with no third-party packages.

```sh
make build      # Build the Debug app
make test       # Run the XCTest suite
make release    # Build and locally sign the Release app
make dmg        # Create dist/codexCycle-<version>-arm64.dmg
make install    # Replace /Applications/codexCycle.app and launch it
make uninstall  # Remove the app and preserve preferences
make purge      # Remove the app and its preferences
```

## Project layout

| Path | Responsibility |
| --- | --- |
| `codexCycle/Domain` | Quota models, selection rules, and remaining calculations |
| `codexCycle/Infrastructure` | Runtime discovery, app-server transport, cache, and login item management |
| `codexCycle/Coordination` | Refresh scheduling, retries, wake handling, and daily requests |
| `codexCycle/Presentation` | Menu-bar indicator, detail panel, localization, and relative time |
| `codexCycleTests` | Parser, cache, Runtime, scheduling, presentation, and regression tests |
| `docs/adr` | Architecture decisions and operational constraints |

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Codex Runtime not found | Install Codex CLI, or install and sign in to the current ChatGPT desktop app |
| Codex Runtime incompatible | Update Codex CLI or ChatGPT, then select **Refresh** |
| Codex is not signed in | Sign in through the corresponding Codex product |
| Launch at Login is off | Turn on **Launch at Login** in the codexCycle panel |
| macOS blocks first launch | Use **Open Anyway** under Privacy & Security |

Read-only diagnostics are available from the installed app.

```sh
/Applications/codexCycle.app/Contents/MacOS/codexCycle --diagnose
```

## Documentation

- [Product specification](docs/product-spec.md)
- [Codex app-server decision](docs/adr/0001-use-codex-app-server-for-rate-limits.md)
- [Non-sandboxed Runtime decision](docs/adr/0002-run-outside-the-app-sandbox.md)
- [Runtime discovery and trust decision](docs/adr/0003-support-independent-and-desktop-codex-runtimes.md)
- [Daily request decision](docs/adr/0004-use-ephemeral-codex-exec-for-daily-five-hour-refresh.md)

## Contributing

Issues and focused pull requests are welcome. Please run `make test` before
opening a pull request and keep behavior changes aligned with the product
specification and architecture decisions.
