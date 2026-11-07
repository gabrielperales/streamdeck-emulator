defmodule StreamdeckEmulatorWeb.RequireJSON do
  @moduledoc """
  Rejects state-changing requests that are not `application/json`.

  Browsers send cross-origin "simple" requests (form or text/plain bodies)
  without asking first, so any web page could otherwise press keys through the
  control API. A JSON body needs a CORS preflight, which the emulator never
  grants.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD", "OPTIONS"],
    do: conn

  def call(conn, _opts) do
    case get_req_header(conn, "content-type") do
      ["application/json" <> _] ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(415, ~s({"error":"send content-type: application/json"}))
        |> halt()
    end
  end
end
