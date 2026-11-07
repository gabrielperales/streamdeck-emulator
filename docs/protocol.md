# What the emulator reproduces

Notes on the Stream Deck app's behaviour that the emulator copies. Each was
checked against a real plugin
([streamdeck-osascript](https://github.com/gabrielperales/streamdeck-osascript),
an Objective-C SDK v2 plugin with the standard Elgato Property Inspector
template), its logs, or a real Stream Deck.

## Plugin folder

- A plugin is a `<uuid>.sdPlugin` folder with a `manifest.json`.
- `CodePath` (or `CodePathMac` / `CodePathWin`) is the executable, relative to
  the folder. The app launches it with the folder as the working directory. A
  `.js`, `.mjs` or `.cjs` `CodePath` runs with Node.js.
- `Actions[].UUID` are the action UUIDs. `Actions[].PropertyInspectorPath`, or
  the top-level `PropertyInspectorPath`, is the PI page.
  `Actions[].States[].Image` is the key image.
- Image paths have no extension: `<name>.png` plus `<name>@2x.png`, or
  `<name>.svg`.

## Launch

```
<CodePath> -port <port> -pluginUUID <uuid> -registerEvent registerPlugin -info '<json>'
```

`-info` looks like
`{"application":{"language":"en","platform":"mac","version":"6.4.0"},"devices":[{"id":"…","type":0,"size":{"columns":5,"rows":3}}]}`.

## Plugin connection

- The plugin connects to `ws://127.0.0.1:<port>`, and the PI to
  `ws://localhost:<port>`, which may resolve to `::1`. Listen on both.
- The plugin first sends `{"event":"registerPlugin","uuid":"<pluginUUID>"}`.
- The Objective-C SDK sends its JSON as binary frames. Accept text and binary.

App → plugin events carry `event`, `action`, `context`, `device` and
`payload`:

- `willAppear` / `willDisappear`, with payload
  `{settings, coordinates:{column,row}, state, isInMultiAction, controller:"Keypad"}`;
- `keyDown` / `keyUp`, with the same payload;
- `didReceiveSettings`, after the PI saves settings (below);
- `propertyInspectorDidAppear` / `propertyInspectorDidDisappear`,
  `deviceDidConnect`, and `sendToPlugin` (from the PI).

Plugin → app events: `setTitle`, `setImage` (a base64 data URL), `showAlert`,
`showOk`, `setState`, `setSettings`, `getSettings`, `logMessage`, `openUrl`,
`sendToPropertyInspector`.

Lifecycle:

- When the app closes the socket, the plugin exits.
- When a plugin crashes, the app relaunches it and sends `willAppear` again for
  every visible key, with its stored settings.

## Property Inspector

The app loads the PI page, then calls this global function in it:

```js
connectElgatoStreamDeckSocket(inPort, inPropertyInspectorUUID, "registerPropertyInspector", inApplicationInfo, inActionInfo)
```

- `inApplicationInfo` and `inActionInfo` are JSON strings. `inActionInfo` is
  `{"action":"<actionUUID>","context":"<context>","device":"…","payload":{"settings":{…},"coordinates":{…}}}`.
- On open, the PI sends `{"event":"registerPropertyInspector","uuid":"<inPropertyInspectorUUID>"}`.
- The PI saves with `{"event":"setSettings","context":"<inPropertyInspectorUUID>","payload":{…}}`,
  and also sends `getSettings`, `sendToPlugin`, `openUrl` and `logMessage`.
  The context it sends is the PI UUID, so the emulator passes the key's context
  as the PI UUID.
- On a PI `setSettings`, the app stores the settings for the key and sends the
  plugin `didReceiveSettings`, with the same payload shape as `willAppear`.
- Plugin `sendToPropertyInspector` reaches the PI as
  `{"event":"sendToPropertyInspector","action","context","payload"}`.
- The template's `sdpi.css` hides the real radio inputs behind styled labels.
  Browser tests should click the label.

## App behaviour worth emulating

- **Executable bit:** `.streamDeckPlugin` packages are zip files that do not
  keep the executable bit, whether made by `streamdeck pack` or the older
  DistributionTool. The app sets it on install, and so does the emulator.
- **Same version is skipped:** the app silently skips installing a package
  whose `Version` matches the installed one, and treats `1.1.0` and `1.1.0.0`
  as equal. The emulator does not install packages, so this does not apply.
- **Category needs a category icon:** the app rejects a manifest with
  `Category` but no `CategoryIcon`. `streamdeck validate` (`@elgato/cli`
  1.10.4) misses this; the emulator checks it.
- **Notifications:** macOS drops `display notification` from an unbundled
  plugin process, so tests should write a marker file instead.

## Not emulated yet

Profiles, multi-actions, encoders and dials (Stream Deck +), and the
Marketplace. Global settings are stored for the session only.
