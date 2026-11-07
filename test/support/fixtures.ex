defmodule StreamdeckEmulator.Fixtures do
  @moduledoc "Test helpers around the echo fixture plugin."

  import ExUnit.Assertions

  @echo Path.expand("../fixtures/echo.sdPlugin", __DIR__)

  def echo_plugin, do: @echo
  def echo_action, do: "com.example.echo.action"

  @doc "Copies the echo plugin into `tmp_dir` and returns the copy's path."
  def copy_echo(tmp_dir) do
    dest = Path.join(tmp_dir, "echo.sdPlugin")
    File.cp_r!(@echo, dest)
    dest
  end

  @doc """
  Copies the echo plugin into `tmp_dir` as a JavaScript plugin (`CodePath`
  "plugin.js", not executable), which the emulator must run with Node.js.
  """
  def node_echo(tmp_dir) do
    dir = copy_echo(tmp_dir)
    File.rename!(Path.join(dir, "plugin"), Path.join(dir, "plugin.js"))
    File.chmod!(Path.join(dir, "plugin.js"), 0o644)

    manifest = Path.join(dir, "manifest.json")

    manifest
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("CodePath", "plugin.js")
    |> Map.put("Nodejs", %{"Version" => "20"})
    |> Jason.encode!()
    |> then(&File.write!(manifest, &1))

    dir
  end

  @doc """
  Zips the echo plugin into a `.streamDeckPlugin` package in `tmp_dir`. Like real
  packages, the archive does not keep the executable bit.
  """
  def package_echo(tmp_dir) do
    package = Path.join(tmp_dir, "echo.streamDeckPlugin")
    root = Path.dirname(@echo)

    files =
      Path.join(@echo, "**")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      # In-memory entries carry no file mode, so the executable bit is lost.
      |> Enum.map(&{String.to_charlist(Path.relative_to(&1, root)), File.read!(&1)})

    {:ok, _} = :zip.create(String.to_charlist(package), files)
    package
  end

  @doc "Retries `fun` until it returns a truthy value, or fails after `timeout` ms."
  def eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(25)
          do_eventually(fun, deadline)
        end
    end
  end
end
