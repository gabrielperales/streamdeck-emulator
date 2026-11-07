defmodule StreamdeckEmulatorWeb.ApiControllerTest do
  use StreamdeckEmulatorWeb.ConnCase, async: false

  import StreamdeckEmulator.Fixtures

  alias StreamdeckEmulator.Session

  setup %{conn: conn} do
    on_exit(&Session.stop/0)
    {:ok, conn: put_req_header(conn, "content-type", "application/json")}
  end

  test "state without a plugin", %{conn: conn} do
    assert conn |> get(~p"/api/state") |> json_response(200) == %{
             "plugin" => nil,
             "ws_port" => nil,
             "keys" => []
           }

    assert conn |> post(~p"/api/keys/0/0/press", %{}) |> json_response(409)
  end

  test "loads a plugin with a layout, presses keys and reads events", %{conn: conn} do
    layout = %{
      "keys" => [
        %{"column" => 1, "row" => 0, "action" => echo_action(), "settings" => %{"title" => "hi"}}
      ]
    }

    state =
      conn |> post(~p"/api/plugin", %{path: echo_plugin(), layout: layout}) |> json_response(200)

    assert %{"plugin" => %{"uuid" => "com.example.echo"}, "ws_port" => port, "keys" => [key]} =
             state

    assert is_integer(port)
    assert %{"column" => 1, "row" => 0, "settings" => %{"title" => "hi"}} = key

    eventually(fn -> title(conn, 1, 0) == "hi" end)

    assert conn |> post(~p"/api/keys/1/0/press", %{hold_ms: 20}) |> response(204)
    eventually(fn -> title(conn, 1, 0) == "pressed 1" end)

    events = conn |> get(~p"/api/events?after=0") |> json_response(200) |> Map.fetch!("events")

    assert Enum.any?(
             events,
             &match?(
               %{"source" => "plugin", "direction" => "out", "data" => %{"event" => "keyDown"}},
               &1
             )
           )

    last = List.last(events)["id"]

    later =
      conn |> get(~p"/api/events?after=#{last}") |> json_response(200) |> Map.fetch!("events")

    assert Enum.all?(later, &(&1["id"] > last))
  end

  test "places, presses and removes keys", %{conn: conn} do
    conn |> post(~p"/api/plugin", %{path: echo_plugin()}) |> json_response(200)

    key =
      conn
      |> put(~p"/api/keys/4/2", %{action: echo_action(), settings: %{a: 1}})
      |> json_response(200)

    assert %{"column" => 4, "row" => 2, "settings" => %{"a" => 1}, "context" => "" <> _} = key

    assert conn |> post(~p"/api/keys/4/2/down", %{}) |> response(204)
    assert conn |> post(~p"/api/keys/4/2/up", %{}) |> response(204)
    assert conn |> delete(~p"/api/keys/4/2") |> response(204)

    assert %{"error" => "empty_key"} =
             conn |> post(~p"/api/keys/4/2/press", %{}) |> json_response(422)

    assert conn |> put(~p"/api/keys/9/9", %{action: echo_action()}) |> json_response(422)
    assert conn |> put(~p"/api/keys/0/0", %{action: "nope"}) |> json_response(422)
    assert conn |> post(~p"/api/keys/0/0/press", %{hold_ms: -1}) |> json_response(422)
  end

  test "reports plugins that cannot load", %{conn: conn} do
    assert %{"error" => error} =
             conn |> post(~p"/api/plugin", %{path: "/nope"}) |> json_response(422)

    assert error =~ "does not exist"
  end

  test "refuses state changes that are not JSON", %{conn: conn} do
    conn =
      conn |> delete_req_header("content-type") |> put_req_header("content-type", "text/plain")

    assert conn |> post(~p"/api/keys/0/0/press", "") |> response(415)
  end

  defp title(conn, column, row) do
    conn
    |> get(~p"/api/state")
    |> json_response(200)
    |> Map.fetch!("keys")
    |> Enum.find_value(fn key ->
      key["column"] == column and key["row"] == row and key["title"]
    end)
  end
end
