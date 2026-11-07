defmodule StreamdeckEmulatorWeb.PluginFileController do
  @moduledoc """
  Serves files from the loaded plugin's folder (key images, and the Property
  Inspector page and its assets) from the emulator's own origin.
  """

  use StreamdeckEmulatorWeb, :controller

  alias StreamdeckEmulator.Deck

  def show(conn, %{"path" => segments}) do
    with true <- Deck.running?(),
         %{manifest: manifest} <- Deck.snapshot(),
         {:ok, relative} <- Path.safe_relative(Path.join(segments)),
         file = Path.join(manifest.dir, relative),
         true <- File.regular?(file) do
      conn
      |> put_resp_content_type(MIME.from_path(file), nil)
      # The plugin folder can change between loads; never cache it.
      |> put_resp_header("cache-control", "no-store")
      |> send_file(200, file)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
