defmodule StreamdeckEmulator.Desktop.TrayTest do
  # Toggles Remote, a named process shared with the rest of the suite.
  use ExUnit.Case, async: false

  alias StreamdeckEmulator.Desktop.Tray
  alias StreamdeckEmulator.Remote

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    on_exit(&Remote.disable/0)
    %{settings_path: Path.join(tmp_dir, "settings.json")}
  end

  # A tray whose shell commands come to the test process. `reply` answers them.
  defp start_tray(settings_path, reply \\ fn _name -> :ok end) do
    test = self()

    send_command = fn name, payload ->
      send(test, {:command, name, payload})
      reply.(name)
    end

    start_supervised!({Tray, name: nil, settings_path: settings_path, send_command: send_command})
  end

  defp click(tray, id) do
    send(tray, {:ex_tauri_event, "tray_menu_click", %{"id" => id}})
    _ = :sys.get_state(tray)
  end

  defp item(items, id), do: Enum.find(items, &(&1.id == id))

  test "sends its items and the default preference once started", %{settings_path: path} do
    start_tray(path)
    default = Tray.default_close_to_tray?()

    assert_receive {:command, "set_tray", %{items: items}}
    assert %{checked: false} = item(items, "phone")
    assert %{checked: ^default} = item(items, "close_to_tray")
    assert_receive {:command, "set_close_to_tray", %{enabled: ^default}}
  end

  test "toggling keep running saves it and tells the shell", %{settings_path: path} do
    tray = start_tray(path)
    default = Tray.default_close_to_tray?()
    toggled = not default
    assert_receive {:command, "set_close_to_tray", %{enabled: ^default}}

    click(tray, "close_to_tray")

    assert_receive {:command, "set_close_to_tray", %{enabled: ^toggled}}
    assert %{"close_to_tray" => ^toggled} = path |> File.read!() |> JSON.decode!()
  end

  test "a saved preference wins over the default", %{settings_path: path} do
    saved = not Tray.default_close_to_tray?()
    File.write!(path, JSON.encode!(%{"close_to_tray" => saved}))

    start_tray(path)

    assert_receive {:command, "set_close_to_tray", %{enabled: ^saved}}
  end

  test "phone access is turned on from the tray, showing the window", %{settings_path: path} do
    tray = start_tray(path)
    assert_receive {:command, "set_tray", _}

    click(tray, "phone")

    assert Remote.enabled?()
    assert_receive {:command, "show_window", _}
    assert_receive {:command, "set_tray", %{items: items}}
    assert %{checked: true} = item(items, "phone")

    click(tray, "phone")

    refute Remote.enabled?()
  end

  test "phone access turned on elsewhere checks the item", %{settings_path: path} do
    tray = start_tray(path)
    assert_receive {:command, "set_tray", _}

    {:ok, _status} = Remote.enable()
    _ = :sys.get_state(tray)

    assert_receive {:command, "set_tray", %{items: items}}
    assert %{checked: true} = item(items, "phone")
  end

  test "keeps trying until the shell is connected", %{settings_path: path} do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    reply = fn
      "set_tray" ->
        if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0,
          do: {:error, :not_connected},
          else: :ok

      _name ->
        :ok
    end

    start_tray(path, reply)

    assert_receive {:command, "set_tray", _}
    refute_received {:command, "set_close_to_tray", _}
    assert_receive {:command, "set_close_to_tray", _}, 2_000
  end
end
