defmodule StreamdeckEmulatorWeb.ApiController do
  @moduledoc """
  JSON control API for scripts and tests. See the README for the endpoints.

  Requests that change state must send `content-type: application/json`, so a
  web page in the user's browser cannot drive the emulator with a simple
  cross-origin request (see `StreamdeckEmulatorWeb.RequireJSON`).
  """

  use StreamdeckEmulatorWeb, :controller

  alias StreamdeckEmulator.{Deck, Layout, Session, SocketServer}
  alias StreamdeckEmulator.Deck.Key

  @max_hold_ms 10_000

  def state(conn, _params) do
    if Deck.running?() do
      json(conn, state_json(Deck.snapshot()))
    else
      json(conn, %{plugin: nil, ws_port: nil, keys: []})
    end
  end

  def load_plugin(conn, %{"path" => path} = params) when is_binary(path) do
    ws_port = Application.get_env(:streamdeck_emulator, :ws_port, 0)

    with {:ok, layout} <- parse_layout(params),
         {:ok, _pid} <- Session.start(path, ws_port: ws_port) |> describe_errors(),
         :ok <- Layout.apply(layout) do
      json(conn, state_json(Deck.snapshot()))
    else
      {:error, errors} -> unprocessable(conn, errors)
    end
  end

  def load_plugin(conn, _params), do: unprocessable(conn, ~s(expected {"path": "..."}))

  def unload_plugin(conn, _params) do
    Session.stop()
    send_resp(conn, 204, "")
  end

  def put_key(conn, %{"action" => action} = params) when is_binary(action) do
    with_deck(conn, fn ->
      with {:ok, coords} <- coords(params),
           settings when is_map(settings) <- Map.get(params, "settings", %{}),
           {:ok, _context} <- Deck.assign_action(coords, action, settings) do
        json(conn, key_json(Deck.snapshot().keys[coords]))
      else
        {:error, reason} -> unprocessable(conn, to_string(reason))
        _ -> unprocessable(conn, "settings must be an object")
      end
    end)
  end

  def put_key(conn, _params),
    do: unprocessable(conn, ~s(expected {"action": "...", "settings": {...}}))

  def delete_key(conn, params) do
    with_deck(conn, fn ->
      case coords(params) do
        {:ok, coords} ->
          Deck.clear_key(coords)
          send_resp(conn, 204, "")

        {:error, reason} ->
          unprocessable(conn, reason)
      end
    end)
  end

  @doc "keyDown, then keyUp after `hold_ms` (default 0)."
  def press(conn, params) do
    hold_ms = Map.get(params, "hold_ms", 0)

    if is_integer(hold_ms) and hold_ms in 0..@max_hold_ms do
      key_events(conn, params, fn coords ->
        with :ok <- Deck.key_down(coords) do
          Process.sleep(hold_ms)
          Deck.key_up(coords)
        end
      end)
    else
      unprocessable(conn, "hold_ms must be an integer from 0 to #{@max_hold_ms}")
    end
  end

  def key_down(conn, params), do: key_events(conn, params, &Deck.key_down/1)
  def key_up(conn, params), do: key_events(conn, params, &Deck.key_up/1)

  @doc "Log entries with an id greater than `after` (default 0), oldest first."
  def events(conn, params) do
    with_deck(conn, fn ->
      case Integer.parse(Map.get(params, "after", "0")) do
        {after_id, ""} ->
          entries = for entry <- Deck.log(), entry.id > after_id, do: event_json(entry)
          json(conn, %{events: entries})

        _ ->
          unprocessable(conn, "after must be an integer")
      end
    end)
  end

  ## Helpers

  defp key_events(conn, params, fun) do
    with_deck(conn, fn ->
      with {:ok, coords} <- coords(params),
           :ok <- fun.(coords) do
        send_resp(conn, 204, "")
      else
        {:error, reason} -> unprocessable(conn, to_string(reason))
      end
    end)
  end

  defp with_deck(conn, fun) do
    if Deck.running?() do
      fun.()
    else
      conn |> put_status(409) |> json(%{error: "no plugin loaded"})
    end
  end

  defp coords(%{"column" => column, "row" => row}) do
    with {column, ""} <- Integer.parse(column),
         {row, ""} <- Integer.parse(row) do
      {:ok, {column, row}}
    else
      _ -> {:error, "column and row must be integers"}
    end
  end

  defp parse_layout(%{"layout" => layout}), do: Layout.parse(layout)
  defp parse_layout(_params), do: {:ok, []}

  defp describe_errors({:error, errors}) when is_list(errors), do: {:error, errors}
  defp describe_errors({:error, error}) when is_binary(error), do: {:error, error}
  defp describe_errors({:error, error}), do: {:error, inspect(error)}
  defp describe_errors(ok), do: ok

  defp unprocessable(conn, errors) do
    conn |> put_status(422) |> json(%{error: errors})
  end

  defp state_json(deck) do
    %{
      plugin: %{
        uuid: deck.manifest.uuid,
        name: deck.manifest.name,
        version: deck.manifest.version,
        dir: deck.manifest.dir,
        status: deck.plugin.status,
        connected: deck.plugin_connected,
        exits: deck.plugin.exits,
        os_pid: deck.plugin.os_pid
      },
      ws_port: SocketServer.port(),
      keys:
        deck.keys
        |> Map.values()
        |> Enum.sort_by(fn %Key{coords: {c, r}} -> {r, c} end)
        |> Enum.map(&key_json/1)
    }
  end

  defp key_json(%Key{coords: {column, row}} = key) do
    %{
      column: column,
      row: row,
      action: key.action,
      context: key.context,
      settings: key.settings,
      state: key.state,
      title: Key.title(key),
      image: Key.image(key),
      feedback:
        case key.feedback do
          {kind, _ref} -> kind
          nil -> nil
        end
    }
  end

  defp event_json(entry) do
    %{
      id: entry.id,
      at: entry.at,
      source: entry.source,
      direction: entry.direction,
      context: entry.context,
      data: entry.data
    }
  end
end
