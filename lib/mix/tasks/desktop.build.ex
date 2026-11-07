defmodule Mix.Tasks.Desktop.Build do
  @shortdoc "Builds the desktop app (Tauri shell + Burrito-wrapped backend)"

  @moduledoc """
  Builds the desktop app for one target.

      MIX_ENV=prod mix desktop.build [--target TRIPLE] [--bundles LIST]
      MIX_ENV=prod mix desktop.build --sidecar-only --target TRIPLE
      mix desktop.build --skip-sidecar --target TRIPLE

  It does in order:

    1. compiles the app and digests its assets (`assets.deploy`);
    2. builds the backend with Burrito for the target and copies it to
       `burrito_out/streamdeck_emulator_desktop-<triple>[.exe]`, the name
       Tauri's `externalBin` looks for;
    3. runs `tauri build --target <triple>`; bundles land in
       `src-tauri/target/<triple>/release/bundle/`.

  Targets:

    * `aarch64-apple-darwin`, `x86_64-apple-darwin`
    * `universal-apple-darwin` - both Mac backends joined with `lipo`, for a
      universal .app/.dmg (needs both Rust targets installed)
    * `x86_64-unknown-linux-gnu` - .deb and AppImage
    * `x86_64-pc-windows-msvc` - .msi and NSIS installer

  The default is the machine's own (`rustc -Vv`).

  Burrito can build any target's backend from macOS or Linux (Windows ones
  need `7z`), but Tauri builds the shell only on the target OS. CI therefore
  builds every backend on Linux with `--sidecar-only`, and each OS then
  bundles with `--skip-sidecar`.

  Options:

    * `--bundles LIST` - passed to Tauri (e.g. `app,dmg` or `deb`)
    * `--sidecar-only` - stop after step 2
    * `--skip-sidecar` - skip steps 1 and 2 and use the backend already in
      `burrito_out/` (this needs neither Elixir assets nor Burrito)
  """

  use Mix.Task

  @release "streamdeck_emulator_desktop"
  @mac_targets ~w(aarch64-apple-darwin x86_64-apple-darwin)
  @targets @mac_targets ++
             ~w(universal-apple-darwin x86_64-unknown-linux-gnu x86_64-pc-windows-msvc)

  @switches [target: :string, bundles: :string, sidecar_only: :boolean, skip_sidecar: :boolean]

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    target = opts[:target] || ExTauri.host_triplet()

    unless target in @targets do
      Mix.raise("unsupported target #{target}; expected one of: #{Enum.join(@targets, ", ")}")
    end

    if opts[:sidecar_only] && opts[:skip_sidecar],
      do: Mix.raise("--sidecar-only and --skip-sidecar exclude each other")

    unless opts[:skip_sidecar], do: build_sidecar(target)
    unless opts[:sidecar_only], do: build_shell(target, opts[:bundles])
  end

  @doc "Where Tauri's `externalBin` expects the backend for `triple`."
  def sidecar_path(triple) do
    suffix = if String.contains?(triple, "windows"), do: ".exe", else: ""
    Path.join("burrito_out", "#{@release}-#{triple}#{suffix}")
  end

  defp build_sidecar(target) do
    if Mix.env() != :prod do
      Mix.raise("build the backend with MIX_ENV=prod (it bundles production assets and config)")
    end

    Mix.Task.run("compile")
    Mix.Task.run("assets.deploy")

    case target do
      "universal-apple-darwin" ->
        Enum.each(@mac_targets, &burrito_release/1)
        lipo!(Enum.map(@mac_targets, &sidecar_path/1), sidecar_path(target))

      _ ->
        burrito_release(target)
    end

    Mix.shell().info("Backend for #{target}: #{sidecar_path(target)}")
  end

  # Burrito builds every target in mix.exs unless BURRITO_TARGET names one. It
  # runs in its own `mix release` so prod dependencies load as in a clean build.
  defp burrito_release(target) do
    Mix.shell().info("Building the backend for #{target} with Burrito…")

    {_, status} =
      System.cmd("mix", ["release", @release, "--overwrite"],
        env: [{"MIX_ENV", "prod"}, {"BURRITO_TARGET", target}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("mix release failed for #{target} (exit #{status})")

    built = Path.join("burrito_out", burrito_name(target))
    File.exists?(built) || Mix.raise("Burrito did not produce #{built}")
    File.cp!(built, sidecar_path(target))
  end

  # Burrito names its output <release>_<target>, with .exe for Windows.
  defp burrito_name(target) do
    suffix = if String.contains?(target, "windows"), do: ".exe", else: ""
    "#{@release}_#{target}#{suffix}"
  end

  # Burrito embeds the release in the executable, so each architecture's file
  # is self-contained and lipo can join them.
  defp lipo!(inputs, output) do
    lipo = System.find_executable("lipo") || System.find_executable("llvm-lipo")
    lipo || Mix.raise("lipo (macOS) or llvm-lipo is needed for universal-apple-darwin")

    {out, status} =
      System.cmd(lipo, ["-create", "-output", output | inputs], stderr_to_stdout: true)

    if status != 0, do: Mix.raise("lipo failed: #{out}")
  end

  defp build_shell(target, bundles) do
    sidecar = sidecar_path(target)

    File.exists?(sidecar) ||
      Mix.raise(
        "#{sidecar} is missing; build it first (MIX_ENV=prod mix desktop.build --sidecar-only --target #{target})"
      )

    bundle_args = if bundles, do: ["--bundles", bundles], else: []
    ExTauri.run_simple(["build", "--target", target | bundle_args])

    Mix.shell().info("Bundles: src-tauri/target/#{target}/release/bundle/")
  end
end
