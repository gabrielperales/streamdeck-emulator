defmodule Mix.Tasks.Streamdeck.Run do
  @shortdoc "Runs the emulator, optionally loading a plugin"

  @moduledoc """
  Runs the emulator's web UI and control API, and loads a plugin.

      mix streamdeck.run [PLUGIN] [options]

  `PLUGIN` is a `.sdPlugin` folder or a `.streamDeckPlugin` package. Without it,
  load one from the UI or with `POST /api/plugin`.

  Options:

    * `--http-port PORT` - port for the UI and API (default 4000; 0 picks a free one)
    * `--ws-port PORT` - port for plugin and Property Inspector connections
      (default 0: a free one)
    * `--layout FILE` - JSON file of keys to place once the plugin is loaded
      (see `StreamdeckEmulator.Layout`)
    * `--open` - open the UI in the default browser

  When everything is up it prints one line that scripts can wait for:

      streamdeck-emulator ready {"url":"http://127.0.0.1:4000","ws_port":53211,"plugin":"/path/to/x.sdPlugin"}

  It builds the CSS and JS once if they are missing, and runs without the
  development file watchers, so it suits CI.
  """

  use Mix.Task

  alias StreamdeckEmulator.{Layout, Session, SocketServer}
  alias StreamdeckEmulatorWeb.Endpoint

  @switches [http_port: :integer, ws_port: :integer, layout: :string, open: :boolean]

  @impl true
  def run(args) do
    {opts, plugin} = parse_args!(args)
    layout = read_layout!(opts[:layout], plugin)

    ensure_assets!()

    # Load config (including config/runtime.exs) first, then override it, so the
    # command line wins over environment variables.
    Mix.Task.run("app.config")
    configure!(opts)
    Mix.Task.run("app.start")

    {:ok, {_ip, http_port}} = Endpoint.server_info(:http)
    url = "http://127.0.0.1:#{http_port}"

    ws_port = if plugin, do: load_plugin!(plugin, opts, layout)

    Mix.shell().info(
      "streamdeck-emulator ready " <>
        Jason.encode!(%{url: url, ws_port: ws_port, plugin: plugin && Path.expand(plugin)})
    )

    if opts[:open], do: open(url)

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  defp parse_args!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> {opts, nil}
      {opts, [plugin], []} -> {opts, plugin}
      {_opts, [_, _ | _], []} -> Mix.raise("expected at most one plugin path")
      {_opts, _argv, invalid} -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp read_layout!(nil, _plugin), do: []
  defp read_layout!(_path, nil), do: Mix.raise("--layout needs a plugin to load")

  defp read_layout!(path, _plugin) do
    case Layout.read(path) do
      {:ok, entries} -> entries
      {:error, message} -> Mix.raise(message)
    end
  end

  defp ensure_assets! do
    unless File.exists?("priv/static/assets/css/app.css") and
             File.exists?("priv/static/assets/js/app.js") do
      Mix.shell().info("Building assets…")
      Mix.Task.run("assets.setup")
      Mix.Task.run("assets.build")
    end
  end

  defp configure!(opts) do
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

    endpoint = Application.get_env(:streamdeck_emulator, Endpoint, [])
    http = Keyword.put(endpoint[:http] || [], :port, Keyword.get(opts, :http_port, 4000))

    Application.put_env(
      :streamdeck_emulator,
      Endpoint,
      Keyword.merge(endpoint, http: http, server: true, watchers: []),
      persistent: true
    )

    # This task loads the plugin itself, after the endpoint is up.
    Application.put_env(:streamdeck_emulator, :plugin_path, nil, persistent: true)

    Application.put_env(:streamdeck_emulator, :ws_port, Keyword.get(opts, :ws_port, 0),
      persistent: true
    )
  end

  defp load_plugin!(plugin, opts, layout) do
    case Session.start(plugin, ws_port: Keyword.get(opts, :ws_port, 0)) do
      {:ok, _pid} ->
        :ok

      {:error, errors} ->
        Mix.raise("cannot load #{plugin}:\n  " <> Enum.join(List.wrap(errors), "\n  "))
    end

    case Layout.apply(layout) do
      :ok -> SocketServer.port()
      {:error, message} -> Mix.raise(message)
    end
  end

  defp open(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
    end
  end

  defp iex_running?, do: Code.ensure_loaded?(IEx) and IEx.started?()
end
