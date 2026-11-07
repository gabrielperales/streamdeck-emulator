# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- The Property Inspector's frame now fits its content. It used to grow with
  every resize and never shrink.

## [0.1.0] - 2026-11-07

First release: run and test Stream Deck SDK v2 plugins without a Stream Deck
or the Stream Deck app.

### Added

- **Plugin runtime.** Loads an unpacked `.sdPlugin` folder or a
  `.streamDeckPlugin` package and launches the plugin with the same arguments
  as the Stream Deck app (`-port`, `-pluginUUID`, `-registerEvent`, `-info`).
  Native plugins run directly, and JavaScript plugins (`.js`, `.mjs` or `.cjs`
  `CodePath`) run with Node.js. `CodePathMac` and `CodePathWin` are honoured.
  The emulator sets the executable bit that packages lose, captures the
  plugin's output, and relaunches a crashed plugin with growing back-off,
  sending `willAppear` again for every key with its stored settings.
- **Manifest checks** on load, including one the Stream Deck app enforces but
  `streamdeck validate` misses: a `Category` needs a `CategoryIcon`.
- **WebSocket protocol** on `127.0.0.1` and `::1`, with text and binary frames:
  `willAppear`/`willDisappear`, `keyDown`/`keyUp`, `deviceDidConnect`,
  settings (`setSettings`, `getSettings`, `didReceiveSettings`), global
  settings for the session, `sendToPlugin`/`sendToPropertyInspector`,
  `setTitle`, `setImage`, `setState`, `showOk`, `showAlert`, `logMessage` and
  `openUrl`.
- **Property Inspector hosting.** Selecting a key loads its PI from the plugin
  folder and calls `connectElgatoStreamDeckSocket` as the app does. Settings
  saved in the PI reach the plugin as `didReceiveSettings`. The PI's console
  output appears in the event log.
- **Web UI** (Phoenix LiveView): a virtual 5×3 device whose keys send
  `keyDown` on press and `keyUp` on release (mouse, touch, Space or Enter) and
  show the titles, images, states and OK/alert feedback the plugin sends; the
  plugin's actions; the selected key's settings; and an event log of every
  message in both directions plus the plugin's output.
- **Phone access.** "Use from a phone" lets phones on the local network use
  the deck: scanning a QR code pairs the phone and opens a full-screen,
  touch-friendly view of the keys. The QR code stays in a collapsible section
  of the UI until you open it. Paired phones can only see and press keys.
  Stopping phone access, or starting it again, unpairs every phone. Off by
  default; `mix streamdeck.run --remote` turns it on at startup.
- **CLI for scripts and CI.** `mix streamdeck.run [PLUGIN]` with
  `--http-port`, `--ws-port`, `--layout` (keys to place at startup), `--open`
  and `--remote`. It prints a machine-readable ready line with the URLs and
  ports.
- **JSON control API** under `/api`: read the deck and the event log, load and
  unload plugins, place and remove actions, and press keys. Requests that
  change state must be `application/json`, so web pages cannot drive it.
- **Desktop app** for macOS (universal), Windows (.msi, NSIS) and
  Ubuntu/Debian (.deb, AppImage), built with
  [ex_tauri](https://github.com/filipecabaco/ex_tauri) and Burrito
  (`mix desktop.build`). It loads plugins from native dialogs or by dropping
  them onto the window, and only the app's own window may use its backend.
- **Tests and CI.** Unit and integration tests with an echo fixture plugin,
  Playwright browser tests (including the real
  [streamdeck-osascript](https://github.com/gabrielperales/streamdeck-osascript)
  when `OSASCRIPT_PLUGIN` is set), a smoke test for each packaged backend, and
  GitHub Actions workflows that test on Linux and build the desktop app for
  every platform. A `v*` tag creates a draft GitHub release with the bundles.

### Known limitations

- One plugin at a time, on one 5×3 keypad device.
- Not emulated: profiles, multi-actions, encoders and dials (Stream Deck +),
  and the Marketplace. Global settings and key layouts are not saved between
  runs.
- The Property Inspector shares the emulator's origin, so its scripts can reach
  the emulator's page. Load only plugins you trust.
- Phones connect over plain HTTP on the local network, so they can only pair
  while both devices are on the same network, and the computer's firewall must
  allow incoming connections for the emulator.
- The desktop builds are not signed or notarized yet, so macOS Gatekeeper and
  Windows SmartScreen warn on first launch.

[Unreleased]: https://github.com/gabrielperales/streamdeck-emulator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/gabrielperales/streamdeck-emulator/releases/tag/v0.1.0
