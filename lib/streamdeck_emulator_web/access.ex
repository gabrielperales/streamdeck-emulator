defmodule StreamdeckEmulatorWeb.Access do
  @moduledoc """
  Who may use the HTTP server.

  - **This machine** (a loopback address): everything, as before. In the
    desktop app that still needs the app's launch token
    (`StreamdeckEmulatorWeb.DesktopToken`).
  - **Another device** (only possible while `StreamdeckEmulator.Remote` is
    enabled): the phone view and the files it loads, once paired. Opening the
    pairing URL (`/remote?pair=<token>`) stores the token in the session; it
    stays valid until remote access is turned off or turned on again.

  The LiveView socket is handled before this plug, so the LiveViews check the
  same session (`StreamdeckEmulatorWeb.RemoteAuth`).
  """

  @behaviour Plug

  import Plug.Conn
  import Bitwise

  alias StreamdeckEmulator.Remote
  alias StreamdeckEmulatorWeb.DesktopToken

  @session_key "remote_pair"
  # What the phone view loads: the page itself and plugin images. Static assets
  # (/assets, /images) are served before this plug.
  @remote_paths ["/remote", "/plugin"]

  def session_key, do: @session_key

  @impl true
  def init(opts), do: DesktopToken.init(opts)

  @impl true
  def call(conn, desktop_opts) do
    if loopback?(conn.remote_ip),
      do: DesktopToken.call(conn, desktop_opts),
      else: remote(conn)
  end

  @doc "Whether an address is this machine."
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped IPv6 (::ffff:127.x.x.x)
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: a >>> 8 == 127
  def loopback?(_), do: false

  @doc """
  LiveView's `check_origin`: pages from this machine, and from this machine's
  LAN addresses while remote access is on.
  """
  def origin_allowed?(%URI{host: host}) do
    host in ["localhost", "127.0.0.1", "::1", "[::1]"] or
      (Remote.enabled?() and host in Remote.lan_addresses())
  end

  defp remote(conn) do
    conn = conn |> fetch_session() |> fetch_query_params()

    cond do
      Map.has_key?(conn.query_params, "pair") -> pair(conn, conn.query_params["pair"])
      not Remote.valid_token?(get_session(conn, @session_key)) -> deny(conn)
      conn.request_path == "/" -> redirect(conn, "/remote")
      allowed_path?(conn.request_path) -> conn
      true -> conn |> send_resp(403, "Phones can only use the deck.\n") |> halt()
    end
  end

  defp pair(conn, token) do
    if Remote.valid_token?(token) do
      conn
      |> configure_session(renew: true)
      |> put_session(@session_key, token)
      |> redirect("/remote")
    else
      deny(conn)
    end
  end

  defp allowed_path?(path),
    do: Enum.any?(@remote_paths, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  defp redirect(conn, to) do
    conn
    |> put_resp_header("location", to)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(303, "")
    |> halt()
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(401, """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Not paired</title></head>
    <body style="font:16px system-ui;margin:2rem;color:#ddd;background:#18181b">
    <h1 style="font-size:1.25rem">This phone is not paired</h1>
    <p>Turn on <b>Use from a phone</b> in the emulator and scan its QR code.
    A code stops working when phone access is turned off or on again.</p>
    </body></html>
    """)
    |> halt()
  end
end
