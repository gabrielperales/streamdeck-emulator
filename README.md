# Stream Deck emulator

A local emulator of the Elgato Stream Deck app for testing Stream Deck SDK v2
plugins without hardware. It launches a plugin the way the Stream Deck app does,
speaks its WebSocket protocol, shows a virtual key grid in the browser and hosts
the plugin's Property Inspector.

Status: early development. See `HANDOFF.md` for the protocol notes and plan.

## Development

The toolchain is pinned in `mise.toml` (Erlang/OTP 27, needed later for the
Burrito-based desktop build).

```sh
mise install
mix setup
mix phx.server   # http://localhost:4000
mix test
```

## Licence

MIT
