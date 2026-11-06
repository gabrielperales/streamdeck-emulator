defmodule StreamdeckEmulator.ManifestTest do
  use ExUnit.Case, async: true

  import StreamdeckEmulator.Fixtures

  alias StreamdeckEmulator.Manifest

  test "loads the echo fixture" do
    assert {:ok, manifest} = Manifest.load(echo_plugin())
    assert manifest.uuid == "com.example.echo"
    assert Manifest.executable(manifest) == Path.join(echo_plugin(), "plugin")

    assert [
             %{
               uuid: "com.example.echo.action",
               property_inspector_path: "pi.html",
               states: [_, _]
             }
           ] = manifest.actions
  end

  test "resolves extension-less images" do
    {:ok, manifest} = Manifest.load(echo_plugin())
    assert Manifest.image_file(manifest, "icon") == Path.join(echo_plugin(), "icon.svg")
    assert Manifest.image_file(manifest, "missing") == nil
  end

  @tag :tmp_dir
  test "rejects a Category without a CategoryIcon", %{tmp_dir: tmp_dir} do
    dir = edit_manifest(tmp_dir, &Map.delete(&1, "CategoryIcon"))
    assert {:error, [error]} = Manifest.load(dir)
    assert error =~ "CategoryIcon"
  end

  @tag :tmp_dir
  test "reports every problem at once", %{tmp_dir: tmp_dir} do
    dir =
      edit_manifest(tmp_dir, fn raw ->
        raw
        |> Map.put("CodePath", "nope")
        |> Map.put("Actions", [%{"Name" => "no uuid"}])
        |> Map.delete("UUID")
      end)

    assert {:error, errors} = Manifest.load(dir)
    assert Enum.any?(errors, &(&1 =~ "UUID is missing"))
    assert Enum.any?(errors, &(&1 =~ "CodePath nope does not exist"))
    assert Enum.any?(errors, &(&1 =~ "Actions[0] has no UUID"))
  end

  @tag :tmp_dir
  test "reports a missing or broken manifest", %{tmp_dir: tmp_dir} do
    assert {:error, [error]} = Manifest.load(tmp_dir)
    assert error =~ "cannot read"

    File.write!(Path.join(tmp_dir, "manifest.json"), "{nope")
    assert {:error, [error]} = Manifest.load(tmp_dir)
    assert error =~ "not valid JSON"
  end

  defp edit_manifest(tmp_dir, fun) do
    dir = copy_echo(tmp_dir)
    path = Path.join(dir, "manifest.json")

    path
    |> File.read!()
    |> Jason.decode!()
    |> fun.()
    |> Jason.encode!()
    |> then(&File.write!(path, &1))

    dir
  end
end
