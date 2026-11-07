defmodule StreamdeckEmulator.MixProject do
  use Mix.Project

  def project do
    [
      app: :streamdeck_emulator,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {StreamdeckEmulator.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "desktop.build": :prod]
    ]
  end

  # The desktop app's backend, wrapped by Burrito into one executable that the
  # Tauri shell runs as its sidecar (see `mix ex_tauri.build`). BURRITO_SKIP
  # builds a plain release, as `mix ex_tauri.dev --sidecar release` expects.
  defp releases do
    [
      streamdeck_emulator_desktop: [
        steps:
          [:assemble] ++
            if(System.get_env("BURRITO_SKIP") == "true", do: [], else: [&Burrito.wrap/1]),
        burrito: [
          targets: [
            "aarch64-apple-darwin": [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:websock_adapter, "~> 0.5"},
      {:ex_tauri, "~> 0.7.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind streamdeck_emulator", "esbuild streamdeck_emulator"],
      "assets.deploy": [
        "tailwind streamdeck_emulator --minify",
        "esbuild streamdeck_emulator --minify",
        "phx.digest"
      ],
      # Builds the desktop app (src-tauri/target/release/bundle/). ex_tauri.build
      # makes the release but not the digested assets prod serves.
      "desktop.build": ["compile", "assets.deploy", "ex_tauri.build"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
