defmodule StreamdeckEmulator.LayoutTest do
  use ExUnit.Case, async: true

  alias StreamdeckEmulator.Layout

  test "parses keys, defaulting settings to an empty object" do
    assert Layout.parse(%{
             "keys" => [
               %{"column" => 0, "row" => 1, "action" => "a", "settings" => %{"x" => 1}},
               %{"column" => 4, "row" => 2, "action" => "b"}
             ]
           }) ==
             {:ok,
              [
                %{coords: {0, 1}, action: "a", settings: %{"x" => 1}},
                %{coords: {4, 2}, action: "b", settings: %{}}
              ]}
  end

  test "points at the bad key" do
    assert {:error, message} =
             Layout.parse(%{
               "keys" => [%{"column" => 0, "row" => 0, "action" => "a"}, %{"column" => "1"}]
             })

    assert message =~ "keys[1]"
    assert {:error, _} = Layout.parse([])
  end

  @tag :tmp_dir
  test "reads a file and reports unreadable or invalid ones", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "layout.json")
    File.write!(path, ~s({"keys": [{"column": 2, "row": 0, "action": "a"}]}))
    assert {:ok, [%{coords: {2, 0}}]} = Layout.read(path)

    File.write!(path, "{")
    assert {:error, message} = Layout.read(path)
    assert message =~ "not valid JSON"

    assert {:error, message} = Layout.read(Path.join(tmp_dir, "missing.json"))
    assert message =~ "cannot read"
  end
end
