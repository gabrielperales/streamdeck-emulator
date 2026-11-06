defmodule StreamdeckEmulator.SocketServer do
  @moduledoc """
  The WebSocket port that plugins and Property Inspectors connect to.

  Plugins connect to `127.0.0.1` and PIs to `localhost`, which macOS may resolve
  to `::1`, so it listens on both loopback addresses with the same port. Port 0
  (the default) picks a free one; read it back with `port/0`.
  """

  use GenServer

  require Logger

  alias StreamdeckEmulator.SocketPlug

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec port() :: :inet.port_number()
  def port, do: GenServer.call(__MODULE__, :port)

  @impl true
  def init(opts) do
    # Bandit.start_link/1 links the listeners to this process. Trap exits so a
    # failed IPv6 bind returns an error here instead of taking the server down.
    Process.flag(:trap_exit, true)

    with {:ok, v4} <- listen({127, 0, 0, 1}, Keyword.get(opts, :port, 0)),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(v4) do
      v6 =
        case listen({0, 0, 0, 0, 0, 0, 0, 1}, port) do
          {:ok, pid} ->
            pid

          {:error, reason} ->
            Logger.warning("plugin socket not listening on ::1: #{inspect(reason)}")
            nil
        end

      {:ok, %{port: port, listeners: Enum.reject([v4, v6], &is_nil/1)}}
    else
      error -> {:stop, {:cannot_listen, error}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    if pid in state.listeners, do: {:stop, reason, state}, else: {:noreply, state}
  end

  defp listen(ip, port) do
    Bandit.start_link(plug: SocketPlug, ip: ip, port: port, startup_log: false)
  end
end
