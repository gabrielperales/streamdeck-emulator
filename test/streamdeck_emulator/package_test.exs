defmodule StreamdeckEmulator.PackageTest do
  use ExUnit.Case, async: true

  import StreamdeckEmulator.Fixtures

  alias StreamdeckEmulator.Package

  test "uses a .sdPlugin folder as is" do
    assert Package.open(echo_plugin()) == {:ok, echo_plugin()}
  end

  @tag :tmp_dir
  test "extracts a .streamDeckPlugin package", %{tmp_dir: tmp_dir} do
    assert {:ok, dir} = Package.open(package_echo(tmp_dir))
    assert Path.basename(dir) == "echo.sdPlugin"
    assert File.regular?(Path.join(dir, "manifest.json"))
  end

  @tag :tmp_dir
  test "refuses entries outside the extraction folder", %{tmp_dir: tmp_dir} do
    package = Path.join(tmp_dir, "evil.streamDeckPlugin")
    {:ok, _} = :zip.create(String.to_charlist(package), [{~c"../evil.txt", "boom"}])
    assert {:error, message} = Package.open(package)
    assert message =~ "unsafe path"
  end

  test "rejects other paths" do
    assert {:error, _} = Package.open("/nonexistent/thing.sdPlugin")
    assert {:error, _} = Package.open(Path.join(echo_plugin(), "manifest.json"))
  end
end
