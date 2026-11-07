defmodule StreamdeckEmulator.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      StreamdeckEmulatorWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:streamdeck_emulator, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: StreamdeckEmulator.PubSub},
      {DynamicSupervisor, name: StreamdeckEmulator.SessionSupervisor, strategy: :one_for_one},
      {StreamdeckEmulator.Remote,
       port: Application.get_env(:streamdeck_emulator, :remote_port, 0)},
      # In the desktop app, stops the backend (and so the plugin) when the window
      # goes away. Elsewhere there is no shell to watch.
      if(StreamdeckEmulator.Desktop.shell?(), do: ExTauri.ShutdownManager),
      # Start to serve requests, typically the last entry
      StreamdeckEmulatorWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: StreamdeckEmulator.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(Enum.reject(children, &is_nil/1), opts) do
      autostart_plugin()
      {:ok, pid}
    end
  end

  # Loads the plugin named by STREAMDECK_PLUGIN (see config/runtime.exs), if any.
  defp autostart_plugin do
    case Application.get_env(:streamdeck_emulator, :plugin_path) do
      nil ->
        :ok

      path ->
        ws_port = Application.get_env(:streamdeck_emulator, :ws_port, 0)

        case StreamdeckEmulator.Session.start(path, ws_port: ws_port) do
          {:ok, _pid} -> :ok
          {:error, reason} -> Logger.error("could not load plugin #{path}: #{inspect(reason)}")
        end
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StreamdeckEmulatorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
