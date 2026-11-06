defmodule StreamdeckEmulator.DeckTest do
  # The Deck is a named process.
  use ExUnit.Case, async: false

  import StreamdeckEmulator.Fixtures

  alias StreamdeckEmulator.{Deck, Manifest}
  alias StreamdeckEmulator.Deck.Key

  # These tests play both sockets: a spawned process stands in for the plugin or
  # a PI connection and forwards what the Deck sends it to the test process.

  setup do
    {:ok, manifest} = Manifest.load(echo_plugin())
    start_supervised!({Deck, manifest: manifest, plugin_uuid: "PLUGIN"})
    :ok
  end

  test "rejects a plugin that registers with the wrong UUID" do
    assert {:error, _} =
             Deck.register(fake_socket(:plugin), %{"event" => "registerPlugin", "uuid" => "OTHER"})
  end

  test "a registering plugin gets deviceDidConnect, then willAppear for every key" do
    {:ok, context} = Deck.assign_action({1, 2}, echo_action(), %{"a" => 1})
    plugin = connect_plugin()

    assert_receive {:plugin, %{"event" => "deviceDidConnect", "device" => "emulator-device"}}

    assert_receive {:plugin,
                    %{
                      "event" => "willAppear",
                      "action" => "com.example.echo.action",
                      "context" => ^context,
                      "payload" => %{
                        "settings" => %{"a" => 1},
                        "coordinates" => %{"column" => 1, "row" => 2},
                        "state" => 0,
                        "isInMultiAction" => false,
                        "controller" => "Keypad"
                      }
                    }}

    Deck.key_down({1, 2})
    assert_receive {:plugin, %{"event" => "keyDown", "context" => ^context}}
    assert Deck.key_down({0, 0}) == {:error, :empty_key}
    assert is_pid(plugin)
  end

  test "rejects unknown actions and coordinates outside the device" do
    assert Deck.assign_action({0, 0}, "nope") == {:error, :unknown_action}
    assert Deck.assign_action({5, 0}, echo_action()) == {:error, :invalid_coordinates}
  end

  test "replacing a key sends willDisappear for the old one" do
    plugin = connect_plugin()
    {:ok, old} = Deck.assign_action({0, 0}, echo_action())
    {:ok, new} = Deck.assign_action({0, 0}, echo_action())
    assert_receive {:plugin, %{"event" => "willDisappear", "context" => ^old}}
    assert_receive {:plugin, %{"event" => "willAppear", "context" => ^new}}
    assert is_pid(plugin)
  end

  test "plugin events update the key" do
    plugin = connect_plugin()
    {:ok, context} = Deck.assign_action({0, 0}, echo_action())

    Deck.incoming(plugin, %{
      "event" => "setTitle",
      "context" => context,
      "payload" => %{"title" => "hi"}
    })

    Deck.incoming(plugin, %{
      "event" => "setImage",
      "context" => context,
      "payload" => %{"image" => "data:x", "state" => 1}
    })

    Deck.incoming(plugin, %{"event" => "showAlert", "context" => context})

    key = Deck.snapshot().keys[{0, 0}]
    assert Key.title(key) == "hi"
    assert Key.image(key) == nil
    assert {:alert, _} = key.feedback

    Deck.incoming(plugin, %{
      "event" => "setState",
      "context" => context,
      "payload" => %{"state" => 1}
    })

    key = Deck.snapshot().keys[{0, 0}]
    assert {Key.title(key), Key.image(key)} == {"hi", "data:x"}
  end

  test "a PI's setSettings is stored and sent to the plugin as didReceiveSettings" do
    _plugin = connect_plugin()
    {:ok, context} = Deck.assign_action({2, 1}, echo_action())
    pi = connect_pi(context)

    assert_receive {:plugin, %{"event" => "propertyInspectorDidAppear", "context" => ^context}}

    # The PI sends its PI UUID as context; the emulator routes by connection.
    Deck.incoming(pi, %{
      "event" => "setSettings",
      "context" => context,
      "payload" => %{"script" => "x"}
    })

    assert_receive {:plugin,
                    %{
                      "event" => "didReceiveSettings",
                      "context" => ^context,
                      "payload" => %{
                        "settings" => %{"script" => "x"},
                        "coordinates" => %{"column" => 2, "row" => 1}
                      }
                    }}

    assert Deck.snapshot().keys[{2, 1}].settings == %{"script" => "x"}

    Deck.incoming(pi, %{"event" => "getSettings", "context" => context})

    assert_receive {:pi,
                    %{
                      "event" => "didReceiveSettings",
                      "payload" => %{"settings" => %{"script" => "x"}}
                    }}
  end

  test "routes sendToPlugin and sendToPropertyInspector" do
    plugin = connect_plugin()
    {:ok, context} = Deck.assign_action({0, 0}, echo_action())
    pi = connect_pi(context)

    Deck.incoming(pi, %{"event" => "sendToPlugin", "context" => context, "payload" => %{"q" => 1}})

    assert_receive {:plugin,
                    %{
                      "event" => "sendToPlugin",
                      "context" => ^context,
                      "action" => _,
                      "payload" => %{"q" => 1}
                    }}

    Deck.incoming(plugin, %{
      "event" => "sendToPropertyInspector",
      "context" => context,
      "payload" => %{"r" => 2}
    })

    assert_receive {:pi,
                    %{
                      "event" => "sendToPropertyInspector",
                      "context" => ^context,
                      "payload" => %{"r" => 2}
                    }}
  end

  test "the plugin's setSettings reaches an open PI" do
    plugin = connect_plugin()
    {:ok, context} = Deck.assign_action({0, 0}, echo_action())
    _pi = connect_pi(context)

    Deck.incoming(plugin, %{
      "event" => "setSettings",
      "context" => context,
      "payload" => %{"n" => 1}
    })

    assert_receive {:pi,
                    %{"event" => "didReceiveSettings", "payload" => %{"settings" => %{"n" => 1}}}}
  end

  test "a closing PI sends propertyInspectorDidDisappear" do
    _plugin = connect_plugin()
    {:ok, context} = Deck.assign_action({0, 0}, echo_action())
    pi = connect_pi(context)

    Process.exit(pi, :kill)
    assert_receive {:plugin, %{"event" => "propertyInspectorDidDisappear", "context" => ^context}}
  end

  test "a PI for an unknown context is rejected" do
    assert {:error, _} =
             Deck.register(fake_socket(:pi), %{
               "event" => "registerPropertyInspector",
               "uuid" => "NOPE"
             })
  end

  defp connect_plugin do
    pid = fake_socket(:plugin)
    assert :ok = Deck.register(pid, %{"event" => "registerPlugin", "uuid" => "PLUGIN"})
    pid
  end

  defp connect_pi(context) do
    pid = fake_socket(:pi)
    assert :ok = Deck.register(pid, %{"event" => "registerPropertyInspector", "uuid" => context})
    pid
  end

  defp fake_socket(tag) do
    test = self()

    spawn(fn ->
      receive_loop = fn loop ->
        receive do
          {:send, msg} ->
            send(test, {tag, msg})
            loop.(loop)

          :close ->
            :ok
        end
      end

      receive_loop.(receive_loop)
    end)
  end
end
