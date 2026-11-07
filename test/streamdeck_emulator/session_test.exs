defmodule StreamdeckEmulator.SessionTest do
  # End to end with the echo fixture: a real process, a real WebSocket.
  use ExUnit.Case, async: false

  import StreamdeckEmulator.Fixtures

  alias StreamdeckEmulator.{Deck, Session}
  alias StreamdeckEmulator.Deck.Key

  setup do
    on_exit(&Session.stop/0)
  end

  test "launches the plugin, which registers and reacts to keys" do
    {:ok, _} = Session.start(echo_plugin())
    eventually(fn -> Deck.snapshot().plugin_connected end)

    {:ok, _context} = Deck.assign_action({0, 0}, echo_action(), %{"title" => "hello"})
    eventually(fn -> title({0, 0}) == "hello" end)

    :ok = Deck.key_down({0, 0})
    :ok = Deck.key_up({0, 0})
    eventually(fn -> title({0, 0}) == "pressed 1" end)
    eventually(fn -> match?(%Key{feedback: {:ok, _}}, Deck.snapshot().keys[{0, 0}]) end)

    # The plugin's stdout ends up in the log.
    eventually(fn ->
      Enum.any?(Deck.log(), &(&1.source == :stdout and &1.data == "received keyDown"))
    end)
  end

  test "relaunches a crashed plugin and re-sends willAppear with stored settings" do
    {:ok, _} = Session.start(echo_plugin())
    eventually(fn -> Deck.snapshot().plugin_connected end)
    {:ok, _} = Deck.assign_action({3, 1}, echo_action(), %{"title" => "kept"})
    :ok = Deck.key_down({3, 1})
    eventually(fn -> title({3, 1}) == "pressed 1" end)

    os_pid = Deck.snapshot().plugin.os_pid
    System.cmd("kill", ["-9", to_string(os_pid)])

    eventually(fn -> Deck.snapshot().plugin.exits == 1 end)

    eventually(fn ->
      Deck.snapshot().plugin_connected and Deck.snapshot().plugin.os_pid != os_pid
    end)

    eventually(fn -> title({3, 1}) == "kept" end)
  end

  @tag :tmp_dir
  test "runs a .streamDeckPlugin package, setting the executable bit", %{tmp_dir: tmp_dir} do
    {:ok, _} = Session.start(package_echo(tmp_dir))
    eventually(fn -> Deck.snapshot().plugin_connected end)
    assert Enum.any?(Deck.log(), &(&1.source == :system and &1.data =~ "was not executable"))
  end

  @tag :tmp_dir
  test "runs a JavaScript plugin with Node.js", %{tmp_dir: tmp_dir} do
    {:ok, _} = Session.start(node_echo(tmp_dir))
    eventually(fn -> Deck.snapshot().plugin_connected end)

    {:ok, _} = Deck.assign_action({0, 0}, echo_action())
    :ok = Deck.key_down({0, 0})
    eventually(fn -> title({0, 0}) == "pressed 1" end)
    refute Enum.any?(Deck.log(), &(&1.source == :system and &1.data =~ "was not executable"))
  end

  test "stopping the session stops the plugin" do
    {:ok, _} = Session.start(echo_plugin())
    eventually(fn -> Deck.snapshot().plugin_connected end)
    os_pid = Deck.snapshot().plugin.os_pid

    :ok = Session.stop()
    refute Session.running?()

    eventually(fn ->
      {_, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
      status != 0
    end)
  end

  test "reports an invalid plugin without starting" do
    assert {:error, [_ | _]} = Session.start(Path.dirname(echo_plugin()))
    refute Session.running?()
  end

  defp title(coords) do
    case Deck.snapshot().keys[coords] do
      nil -> nil
      key -> Key.title(key)
    end
  end
end
