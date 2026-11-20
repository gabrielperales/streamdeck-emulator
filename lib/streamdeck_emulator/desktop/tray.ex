defmodule StreamdeckEmulator.Desktop.Tray do
  @moduledoc """
  The backend's items in the desktop app's tray menu, and the "keep running
  when the window is closed" preference.

  The shell owns the tray icon and its Show and Quit items, which work whatever
  state the backend is in. This process adds, between them:

    * **Phone access**, checked while phones may use the deck. Turning it on
      shows the window, since pairing a phone needs the QR code.
    * **Keep running when closed**, checked while closing the window hides it
      to the tray instead of quitting. It is saved in `settings.json` in the
      app's config directory and sent to the shell, which applies it.

  Commands go over ExTauri's desktop channel, which only exists once the shell
  has connected, so they are sent again every second until one gets through.
  Only started inside the desktop app (see `StreamdeckEmulator.Desktop`).
  """

  use GenServer

  require Logger

  alias StreamdeckEmulator.Remote

  @retry_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether closing the window keeps the app running, before the user has said:
  yes, except on Linux, where GNOME shows no tray icons without an extension.
  The shell starts with the same default.
  """
  @spec default_close_to_tray?() :: boolean()
  def default_close_to_tray? do
    # Under ampoule the sidecar reports Linux on every host; the shell names
    # the real one.
    case System.get_env("EX_TAURI_HOST_OS") do
      nil -> :os.type() != {:unix, :linux}
      os -> os != "linux"
    end
  end

  ## Server

  @impl true
  def init(opts) do
    Remote.subscribe()
    # {:error, :not_running} outside the shell (tests); clicks then never come.
    _ = ExTauri.Desktop.subscribe()

    settings_path =
      Keyword.get_lazy(opts, :settings_path, fn ->
        Path.join(ExTauri.Paths.config_dir(), "settings.json")
      end)

    state = %{
      settings_path: settings_path,
      close_to_tray: load_close_to_tray(settings_path),
      send_command: Keyword.get(opts, :send_command, &send_command/2),
      retry: nil
    }

    {:ok, state, {:continue, :push}}
  end

  @impl true
  def handle_continue(:push, state), do: {:noreply, push(state)}

  @impl true
  def handle_info(:push, state), do: {:noreply, push(%{state | retry: nil})}

  def handle_info({:remote, _status}, state), do: {:noreply, push(state)}

  def handle_info({:ex_tauri_event, "tray_menu_click", %{"id" => "phone"}}, state) do
    if Remote.enabled?() do
      Remote.disable()
    else
      case Remote.enable() do
        {:ok, _status} -> state.send_command.("show_window", %{})
        {:error, reason} -> Logger.error("could not turn on phone access: #{inspect(reason)}")
      end
    end

    # Remote broadcasts the change, and that pushes the menu; this push puts the
    # check mark back where it was if enabling failed.
    {:noreply, push(state)}
  end

  def handle_info({:ex_tauri_event, "tray_menu_click", %{"id" => "close_to_tray"}}, state) do
    state = %{state | close_to_tray: not state.close_to_tray}
    save_close_to_tray(state.settings_path, state.close_to_tray)
    {:noreply, push(state)}
  end

  def handle_info({:ex_tauri_event, _name, _payload}, state), do: {:noreply, state}

  # Sends the menu and the preference; on failure (no shell connected yet) tries
  # again shortly, once.
  defp push(state) do
    tray = %{
      tooltip: "Stream Deck Emulator",
      items: [
        %{id: "phone", label: "Phone access", checked: Remote.enabled?()},
        %{id: "close_to_tray", label: "Keep running when closed", checked: state.close_to_tray}
      ]
    }

    with :ok <- state.send_command.("set_tray", tray),
         :ok <- state.send_command.("set_close_to_tray", %{enabled: state.close_to_tray}) do
      state
    else
      _error when is_nil(state.retry) ->
        %{state | retry: Process.send_after(self(), :push, @retry_ms)}

      _error ->
        state
    end
  end

  # ExTauri.Desktop.set_tray/1 keeps only each item's id and label, and has no
  # call for the shell's set_close_to_tray and show_window commands, so they
  # go to the channel the way it sends its own.
  defp send_command(name, payload) do
    case Process.whereis(ExTauri.ShutdownManager) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:desktop_command, name, payload})
    end
  end

  defp load_close_to_tray(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"close_to_tray" => value}} when is_boolean(value) <- JSON.decode(body) do
      value
    else
      _ -> default_close_to_tray?()
    end
  end

  defp save_close_to_tray(path, value) do
    settings =
      with {:ok, body} <- File.read(path),
           {:ok, %{} = settings} <- JSON.decode(body) do
        settings
      else
        _ -> %{}
      end

    case File.write(path, JSON.encode!(Map.put(settings, "close_to_tray", value))) do
      :ok -> :ok
      {:error, reason} -> Logger.error("could not save #{path}: #{inspect(reason)}")
    end
  end
end
