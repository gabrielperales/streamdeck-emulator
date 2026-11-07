defmodule StreamdeckEmulatorWeb.DesktopToken do
  @moduledoc """
  In the desktop app, only the app's own window may use the HTTP server: this
  applies `ExTauri.Token.Plug`, which trades the shell's launch token for a
  cookie. Outside the desktop app (CLI, CI, tests) it does nothing, so the
  control API keeps working without a token.
  """

  @behaviour Plug

  alias StreamdeckEmulator.Desktop

  @impl true
  def init(opts), do: ExTauri.Token.Plug.init(opts)

  @impl true
  def call(conn, opts) do
    if Desktop.shell?(), do: ExTauri.Token.Plug.call(conn, opts), else: conn
  end
end
