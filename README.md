# Stream Deck emulator

A local emulator of the Elgato Stream Deck app for testing Stream Deck SDK v2
plugins without hardware. It:

- launches a plugin the way the Stream Deck app does and speaks its WebSocket
  protocol, relaunching the plugin if it crashes;
- shows a virtual 5×3 device in the browser: press keys and see the titles,
  images and OK/alert feedback the plugin sends back;
- hosts the plugin's Property Inspector (PI) and connects it, so settings edited
  in the PI reach the plugin;
- has a JSON control API and a CLI for scripts and CI.

Status: early development. Profiles, multi-actions, encoders (Stream Deck +)
and the Marketplace are out of scope for now.

## Running it

The toolchain is pinned in `mise.toml` (Erlang/OTP 27, Elixir 1.20, Node 24).

```sh
mise install
mix setup
mix streamdeck.run path/to/com.example.plugin.sdPlugin --open
```

The argument can be an unpacked `.sdPlugin` folder or a `.streamDeckPlugin`
package. Without it, load a plugin from the UI.

| Option | Default | |
|---|---|---|
| `--http-port PORT` | 4000 | UI and control API; 0 picks a free port |
| `--ws-port PORT` | 0 (free port) | Plugin and PI WebSocket connections |
| `--layout FILE` | | Keys to place once the plugin loads (below) |
| `--open` | | Open the UI in the browser |

When everything is up, it prints a line that scripts can wait for:

```
streamdeck-emulator ready {"url":"http://127.0.0.1:4000","ws_port":53211,"plugin":"/path/to/x.sdPlugin"}
```

During development, `mix phx.server` also works, with the plugin in
`STREAMDECK_PLUGIN` and an optional `STREAMDECK_WS_PORT`.

Everything listens on loopback only. Plugins connect to `127.0.0.1` and PIs to
`localhost`, so the WebSocket port listens on both `127.0.0.1` and `::1`.

### Layout file

```json
{
  "keys": [
    { "column": 0, "row": 0, "action": "com.example.plugin.action", "settings": { "a": 1 } }
  ]
}
```

## Control API

All bodies are JSON. Requests that change state must send
`content-type: application/json`; others get `415`, so web pages open in your
browser cannot drive the emulator. Endpoints that need a plugin return `409`
when none is loaded, and invalid input gets `422` with `{"error": ...}`.

| Method and path | Body | Does |
|---|---|---|
| `GET /api/state` | | Plugin status, WebSocket port and keys (`plugin` is `null` with nothing loaded) |
| `GET /api/events?after=ID` | | Log entries after `ID`: messages both ways, plugin output, PI console |
| `POST /api/plugin` | `{"path": "...", "layout": {...}}` | Loads a plugin, replacing the current one; `layout` is optional |
| `DELETE /api/plugin` | | Stops the plugin |
| `PUT /api/keys/:column/:row` | `{"action": "...", "settings": {...}}` | Places an action (`willAppear`) |
| `DELETE /api/keys/:column/:row` | | Removes it (`willDisappear`) |
| `POST /api/keys/:column/:row/press` | `{"hold_ms": 0}` | `keyDown`, then `keyUp` |
| `POST /api/keys/:column/:row/down` and `/up` | `{}` | One of the two |

Each key in `/api/state` has `column`, `row`, `action`, `context`, `settings`,
`state`, `title`, `image` and `feedback` (`"ok"`, `"alert"` or `null`).

## How the Property Inspector is hosted

Selecting a key loads its PI from the plugin folder, served under `/plugin/` on
the emulator's own origin, in an iframe. Once the page loads, the emulator calls
`connectElgatoStreamDeckSocket(port, uuid, "registerPropertyInspector",
applicationInfo, actionInfo)` in it, using the key's context as the PI UUID. The
PI's console output shows up in the event log.

Because the PI shares the emulator's origin, its scripts can reach the
emulator's page. That is fine for your own plugin; don't load plugins you don't
trust.

## Tests

```sh
mix test                   # unit and integration tests, with an echo fixture plugin

cd e2e
npm ci
npx playwright install chromium
npx playwright test        # browser tests; starts the emulator on port 4100
```

`test/fixtures/echo.sdPlugin` is a small Node plugin and PI that echo what they
receive, so the tests need neither Xcode nor a real plugin. To also run the
browser tests against [streamdeck-osascript](https://github.com/gabrielperales/streamdeck-osascript)
(macOS only), point `OSASCRIPT_PLUGIN` at a build of it:

```sh
OSASCRIPT_PLUGIN=/path/to/com.gabrielperales.osascript.streamDeckPlugin npx playwright test
```

## Licence

MIT
