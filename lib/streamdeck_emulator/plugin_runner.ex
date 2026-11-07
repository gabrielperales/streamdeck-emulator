defmodule StreamdeckEmulator.PluginRunner do
  @moduledoc """
  Launches the plugin the way the Stream Deck app does (its executable, or Node.js
  for a JavaScript `CodePath`), forwards its output to the Deck's log and
  relaunches it when it exits.

  Relaunches back off from 0.5 s up to 10 s; a plugin that stayed up for 30 s
  starts again from the shortest delay.
  """

  use GenServer

  alias StreamdeckEmulator.{Deck, Manifest}

  @first_delay 500
  @max_delay 10_000
  @stable_after 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The command-line arguments the Stream Deck app passes to a plugin."
  @spec launch_args(:inet.port_number(), String.t(), map()) :: [String.t()]
  def launch_args(port, plugin_uuid, info) do
    [
      "-port",
      to_string(port),
      "-pluginUUID",
      plugin_uuid,
      "-registerEvent",
      "registerPlugin",
      "-info",
      Jason.encode!(info)
    ]
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      manifest: Keyword.fetch!(opts, :manifest),
      plugin_uuid: Keyword.fetch!(opts, :plugin_uuid),
      ws_port: Keyword.fetch!(opts, :ws_port),
      port: nil,
      os_pid: nil,
      buffer: "",
      restarts: 0,
      started_at: nil
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, state), do: {:noreply, launch(state)}

  @impl true
  def handle_info(:launch, state), do: {:noreply, launch(state)}

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    Deck.plugin_output(state.buffer <> line)
    {:noreply, %{state | buffer: ""}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if state.buffer != "", do: Deck.plugin_output(state.buffer)
    Deck.plugin_exited(status)

    lived = System.monotonic_time(:millisecond) - state.started_at
    restarts = if lived >= @stable_after, do: 0, else: state.restarts
    delay = min(@first_delay * 2 ** restarts, @max_delay)
    Deck.system_log("relaunching the plugin in #{delay} ms")
    Process.send_after(self(), :launch, delay)

    {:noreply, %{state | port: nil, os_pid: nil, buffer: "", restarts: restarts + 1}}
  end

  # Port exits are already reported through :exit_status.
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    stop_process(os_pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp stop_process(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"], stderr_to_stdout: true)

      # The shell's built-in kill: minimal Linux systems have no /bin/kill.
      _ ->
        :os.cmd(~c"kill -TERM #{os_pid}")
    end
  end

  defp launch(state) do
    manifest = state.manifest
    args = launch_args(state.ws_port, state.plugin_uuid, Deck.application_info(manifest))

    with {:ok, executable, args} <- command(manifest, args) do
      spawn_plugin(state, executable, args)
    else
      {:error, message} ->
        Deck.system_log(message)
        Deck.plugin_exited(:launch_failed)
        state
    end
  end

  # Native plugins run directly; JavaScript plugins run with Node.js, as the
  # Stream Deck app does with the Node.js it bundles.
  defp command(%Manifest{runtime: :native} = manifest, args) do
    executable = Manifest.executable(manifest)
    ensure_executable(executable)
    {:ok, executable, args}
  end

  defp command(%Manifest{runtime: :node} = manifest, args) do
    case node_executable() do
      nil ->
        {:error,
         "cannot run #{manifest.code_path}: Node.js not found (install it, or set STREAMDECK_NODE to its path)"}

      node ->
        {:ok, node, [Manifest.executable(manifest) | args]}
    end
  end

  defp node_executable do
    case System.get_env("STREAMDECK_NODE") do
      path when path not in [nil, ""] -> path
      _ -> System.find_executable("node")
    end
  end

  defp spawn_plugin(state, executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 65_536},
        {:cd, state.manifest.dir},
        {:args, args}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Deck.plugin_launched(os_pid)
    %{state | port: port, os_pid: os_pid, started_at: System.monotonic_time(:millisecond)}
  rescue
    error ->
      Deck.system_log("could not launch #{executable}: #{Exception.message(error)}")
      Deck.plugin_exited(:launch_failed)
      state
  end

  # Packages don't keep the executable bit; the Stream Deck app sets it on
  # install. Windows has no such bit.
  defp ensure_executable(path) do
    with {:unix, _} <- :os.type(),
         {:ok, %File.Stat{mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o111) == 0 do
      File.chmod!(path, Bitwise.bor(mode, 0o111))

      Deck.system_log(
        "#{Path.basename(path)} was not executable; set +x as the Stream Deck app does"
      )
    end
  end
end
