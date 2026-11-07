# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :streamdeck_emulator,
  generators: [timestamp_type: :utc_datetime]

# Desktop app (ex_tauri). In the packaged app the Tauri shell picks a free port
# and passes it as PORT; this port is only used by `mix ex_tauri.dev`.
config :ex_tauri,
  app_name: "Stream Deck Emulator",
  window_title: "Stream Deck Emulator",
  host: "localhost",
  port: 4000,
  width: 1280,
  height: 860,
  resize: true,
  version: "2.5.1",
  release_name: "streamdeck_emulator_desktop"

# Configure the endpoint
config :streamdeck_emulator, StreamdeckEmulatorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: StreamdeckEmulatorWeb.ErrorHTML, json: StreamdeckEmulatorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: StreamdeckEmulator.PubSub,
  # This machine, plus its LAN addresses while phones may connect.
  check_origin: {StreamdeckEmulatorWeb.Access, :origin_allowed?, []},
  live_view: [signing_salt: "IQvHuTAy"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  streamdeck_emulator: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  streamdeck_emulator: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
