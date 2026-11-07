defmodule StreamdeckEmulatorWeb.RemoteAccessTest do
  # Requests "from a phone" are conns with a LAN remote_ip.
  use StreamdeckEmulatorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import StreamdeckEmulator.Fixtures

  alias StreamdeckEmulator.{Deck, Remote, Session}
  alias StreamdeckEmulatorWeb.Access

  @phone {192, 168, 1, 50}

  setup do
    on_exit(fn ->
      Remote.disable()
      Session.stop()
    end)
  end

  test "phones get nothing while phone access is off", %{conn: conn} do
    assert conn |> from_phone() |> get(~p"/remote") |> response(401) =~ "not paired"
    assert conn |> from_phone() |> get(~p"/") |> response(401)
    assert conn |> from_phone() |> get(~p"/api/state") |> response(401)
  end

  test "pairing with the QR code's token gives access to the phone view only", %{conn: conn} do
    token = enable!()

    assert conn |> from_phone() |> get(~p"/remote?pair=wrong") |> response(401)

    paired = conn |> from_phone() |> get(~p"/remote?pair=#{token}")
    assert redirected_to(paired, 303) == "/remote"

    phone = paired |> recycle() |> from_phone()
    assert phone |> get(~p"/remote") |> html_response(200) =~ "No plugin loaded"
    assert phone |> get(~p"/") |> redirected_to(303) == "/remote"
    assert phone |> get(~p"/api/state") |> response(403)
    # Plugin images are allowed through (here there is no plugin, so 404).
    assert phone |> get("/plugin/icon.svg") |> response(404)
  end

  test "stopping phone access, or starting it again, unpairs phones", %{conn: conn} do
    phone = pair!(conn)
    assert phone |> get(~p"/remote") |> response(200)

    enable!()
    assert phone |> get(~p"/remote") |> response(401)

    phone = pair!(conn)
    Remote.disable()
    assert phone |> get(~p"/remote") |> response(401)
  end

  test "a paired phone presses keys and is dropped when unpaired", %{conn: conn} do
    {:ok, _} = Session.start(echo_plugin())
    eventually(fn -> Deck.snapshot().plugin_connected end)
    {:ok, _} = Deck.assign_action({2, 1}, echo_action(), %{"title" => "hi"})

    phone = pair!(conn)
    {:ok, view, html} = live(phone, ~p"/remote")
    assert html =~ "Echo"
    eventually(fn -> has_element?(view, "#key-2-1 [data-role=title]", "hi") end)

    render_hook(view, "key_down", %{"col" => "2", "row" => "1"})
    render_hook(view, "key_up", %{"col" => "2", "row" => "1"})
    eventually(fn -> has_element?(view, "#key-2-1 [data-role=title]", "pressed 1") end)

    # The phone view has no inspector, log or plugin controls.
    refute has_element?(view, "#key-inspector")
    refute has_element?(view, "#event-log")

    Remote.disable()
    assert_redirect(view, "/remote")
  end

  test "this machine can open the phone view without pairing", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/remote")
    assert html =~ "No plugin loaded"
  end

  test "the full UI turns phone access on and shows the pairing code", %{conn: conn} do
    {:ok, _} = Session.start(echo_plugin())
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#phone-access")

    view |> element("#toggle-remote") |> render_click()
    assert Remote.enabled?()
    assert has_element?(view, "#phone-access")

    if Remote.status().host do
      # The code is there, but collapsed until asked for.
      assert has_element?(view, "#pairing-qr svg")
      assert has_element?(view, "#phone-access details:not([open]) #pairing-qr")
    end

    view |> element("#toggle-remote") |> render_click()
    refute Remote.enabled?()
    refute has_element?(view, "#phone-access")
  end

  test "LiveView accepts origins from this machine, and its LAN addresses only while enabled" do
    assert Access.origin_allowed?(URI.parse("http://localhost:4000"))
    assert Access.origin_allowed?(URI.parse("http://127.0.0.1:4000"))
    refute Access.origin_allowed?(URI.parse("http://evil.example"))

    case Remote.lan_addresses() do
      [ip | _] ->
        refute Access.origin_allowed?(URI.parse("http://#{ip}:1234"))
        enable!()
        assert Access.origin_allowed?(URI.parse("http://#{ip}:1234"))

      [] ->
        :ok
    end
  end

  test "loopback addresses" do
    assert Access.loopback?({127, 0, 0, 1})
    assert Access.loopback?({0, 0, 0, 0, 0, 0, 0, 1})
    assert Access.loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
    refute Access.loopback?(@phone)
  end

  defp from_phone(conn), do: %{conn | remote_ip: @phone}

  defp enable! do
    {:ok, _status} = Remote.enable()
    # The token, whether or not this machine has a LAN address for the URL.
    :persistent_term.get({Remote, :token})
  end

  defp pair!(conn) do
    token = enable!()
    conn |> from_phone() |> get(~p"/remote?pair=#{token}") |> recycle() |> from_phone()
  end
end
