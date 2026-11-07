defmodule StreamdeckEmulator.Session do
  @moduledoc """
  One loaded plugin: its Deck, WebSocket port and running process.

  At most one session runs at a time. `start/2` takes a `.sdPlugin` folder or a
  `.streamDeckPlugin` package. Both functions broadcast `{:session, :started}` or
  `{:session, :stopped}` on the Deck's PubSub topic.

  Options:

    * `:ws_port` - port for plugin and PI connections (default 0: any free port)
  """

  use Supervisor

  alias StreamdeckEmulator.{Deck, Manifest, Package, PluginRunner, SocketServer}

  @sessions StreamdeckEmulator.SessionSupervisor

  @spec start(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(path, opts \\ []) do
    with {:ok, dir} <- Package.open(path),
         {:ok, manifest} <- Manifest.load(dir) do
      stop()

      with {:ok, pid} <-
             DynamicSupervisor.start_child(
               @sessions,
               {__MODULE__, Keyword.put(opts, :manifest, manifest)}
             ) do
        Deck.broadcast({:session, :started})
        {:ok, pid}
      end
    end
  end

  @spec stop() :: :ok
  def stop do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@sessions), is_pid(pid) do
      DynamicSupervisor.terminate_child(@sessions, pid)
      Deck.broadcast({:session, :stopped})
    end

    :ok
  end

  @spec running?() :: boolean()
  def running?, do: DynamicSupervisor.count_children(@sessions).active > 0

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    manifest = Keyword.fetch!(opts, :manifest)
    plugin_uuid = Base.encode16(:crypto.strong_rand_bytes(16))

    children = [
      {Deck, manifest: manifest, plugin_uuid: plugin_uuid},
      {SocketServer, port: Keyword.get(opts, :ws_port, 0)},
      %{
        id: PluginRunner,
        start: {__MODULE__, :start_runner, [[manifest: manifest, plugin_uuid: plugin_uuid]]}
      }
    ]

    # Without the Deck or the socket nothing downstream makes sense.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  def start_runner(opts), do: PluginRunner.start_link([{:ws_port, SocketServer.port()} | opts])
end
