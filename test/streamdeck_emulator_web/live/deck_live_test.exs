defmodule StreamdeckEmulatorWeb.DeckLiveTest do
  # Drives a real session with the echo fixture plugin.
  use StreamdeckEmulatorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import StreamdeckEmulator.Fixtures

  alias StreamdeckEmulator.{Deck, Session}

  setup do
    on_exit(&Session.stop/0)
  end

  test "loads a plugin from the form and reports invalid paths", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Load plugin"

    view |> form("#load-form", %{path: "/nonexistent.sdPlugin"}) |> render_submit()
    assert has_element?(view, "#load-errors", "does not exist")

    view |> form("#load-form", %{path: echo_plugin()}) |> render_submit()
    assert has_element?(view, "h1", "Echo")
    eventually(fn -> has_element?(view, "#plugin-status", "Connected") end)

    view |> element("#unload-plugin") |> render_click()
    assert has_element?(view, "#load-form")
  end

  test "places an action, presses the key and shows what the plugin draws", %{conn: conn} do
    {:ok, _} = Session.start(echo_plugin())
    eventually(fn -> Deck.snapshot().plugin_connected end)
    {:ok, view, _html} = live(conn, ~p"/")

    # Actions are disabled until a key is selected; pressing an empty key selects it.
    assert has_element?(view, "#action-com\\.example\\.echo\\.action[disabled]")
    render_hook(view, "key_down", %{"col" => "1", "row" => "2"})
    render_hook(view, "key_up", %{"col" => "1", "row" => "2"})
    assert has_element?(view, "#key-1-2[aria-pressed=true]")

    view |> element("#action-com\\.example\\.echo\\.action") |> render_click()
    assert has_element?(view, "#key-1-2 img[src='/plugin/icon.svg']")
    assert has_element?(view, "#key-inspector", "Echo")

    render_hook(view, "key_down", %{"col" => "1", "row" => "2"})
    render_hook(view, "key_up", %{"col" => "1", "row" => "2"})
    eventually(fn -> has_element?(view, "#key-1-2 [data-role=title]", "pressed 1") end)
    eventually(fn -> has_element?(view, "#key-1-2 [data-feedback=ok]") end)
    eventually(fn -> has_element?(view, "#event-log", "keyDown") end)
    eventually(fn -> has_element?(view, "#event-log", "received keyDown") end)

    view |> element("#clear-key") |> render_click()
    refute has_element?(view, "#key-1-2 img")
  end

  test "shows settings and follows plugin restarts", %{conn: conn} do
    {:ok, _} = Session.start(echo_plugin())
    eventually(fn -> Deck.snapshot().plugin_connected end)
    {:ok, _} = Deck.assign_action({0, 0}, echo_action(), %{"title" => "hi"})
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "key_down", %{"col" => "0", "row" => "0"})
    assert has_element?(view, "#key-settings", ~s("title": "hi"))

    System.cmd("kill", ["-9", to_string(Deck.snapshot().plugin.os_pid)])
    eventually(fn -> has_element?(view, "#plugin-status", "1 restarts") end)
    eventually(fn -> has_element?(view, "#plugin-status", "Connected") end)
  end

  test "embeds the Property Inspector with the arguments the app passes it", %{conn: conn} do
    {:ok, _} = Session.start(echo_plugin())
    {:ok, context} = Deck.assign_action({2, 0}, echo_action(), %{"title" => "x"})
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "iframe")
    render_hook(view, "key_down", %{"col" => "2", "row" => "0"})

    frame = view |> element("#pi-frame-#{context}") |> render() |> LazyHTML.from_fragment()
    attr = fn name -> frame |> LazyHTML.attribute(name) |> hd() end

    assert attr.("src") == "/plugin/pi.html"
    assert attr.("data-uuid") == context
    assert attr.("data-port") == to_string(StreamdeckEmulator.SocketServer.port())

    assert %{
             "action" => "com.example.echo.action",
             "context" => ^context,
             "device" => "emulator-device",
             "payload" => %{
               "settings" => %{"title" => "x"},
               "coordinates" => %{"column" => 2, "row" => 0}
             }
           } = Jason.decode!(attr.("data-action-info"))

    assert %{"application" => %{"platform" => "mac"}, "plugin" => %{"uuid" => "com.example.echo"}} =
             Jason.decode!(attr.("data-app-info"))

    # Console output from the PI page lands in the event log.
    render_hook(view, "pi_log", %{"uuid" => context, "level" => "warn", "message" => "careful"})
    eventually(fn -> has_element?(view, "#event-log", "careful") end)
  end

  test "ignores Tauri bridge replies nobody waits for", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "tauri_response", %{
      "command" => "event_listen",
      "event" => "tauri://drag-drop",
      "ref" => "1",
      "status" => "already_listening"
    })

    assert render(view) =~ "Load plugin"
    # Outside the desktop app there are no native dialogs.
    refute has_element?(view, "#pick-folder")
  end

  describe "plugin files" do
    test "are served from the loaded plugin's folder", %{conn: conn} do
      {:ok, _} = Session.start(echo_plugin())

      conn = get(conn, "/plugin/icon.svg")
      assert response(conn, 200) =~ "<svg"
      assert response_content_type(conn, :svg) =~ "image/svg+xml"
    end

    test "never leave the plugin folder", %{conn: conn} do
      {:ok, _} = Session.start(echo_plugin())
      assert conn |> get("/plugin/../deck_test.exs") |> response(404)
      assert conn |> get("/plugin/%2E%2E/manifest_test.exs") |> response(404)
    end

    test "are not found without a plugin", %{conn: conn} do
      assert conn |> get("/plugin/icon.svg") |> response(404)
    end
  end
end
