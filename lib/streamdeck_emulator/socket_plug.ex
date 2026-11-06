defmodule StreamdeckEmulator.SocketPlug do
  @moduledoc "Upgrades any request on the plugin port to a `StreamdeckEmulator.SocketHandler`."

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if websocket?(conn) do
      conn
      # The app never times out an idle plugin, so neither does the emulator.
      |> WebSockAdapter.upgrade(StreamdeckEmulator.SocketHandler, [], timeout: :infinity)
      |> halt()
    else
      conn |> send_resp(426, "This port only accepts WebSocket connections\n") |> halt()
    end
  end

  defp websocket?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end
end
