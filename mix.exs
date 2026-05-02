defmodule LlmLspMcp.MixProject do
  use Mix.Project

  @app :llm_lsp_mcp
  @version "0.0.1"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [mix_gleam: "~> 0.6"],
      compilers: [:gleam | Mix.compilers()],
      erlc_paths: ["build/dev/erlang/#{@app}/_gleam_artefacts"],
      erlc_include_path: "build/dev/erlang/#{@app}/include",
      prune_code_paths: false,
      deps: deps(),
      releases: releases(),
      aliases: aliases(),
      start_permanent: Mix.env() == :prod
    ]
  end

  # OTP application callback module is wired in Milestone 1, once the
  # supervisor tree exists. For Milestone 0 the app boots empty.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:gleam_stdlib, "~> 1.0"},
      {:gleam_otp, "~> 1.2"},
      {:gleam_erlang, "~> 1.3"},
      {:gleam_json, "~> 3.1"},
      {:pollux, "~> 1.0"},
      {:gleeunit, "~> 1.10", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.5", runtime: false}
    ]
  end

  defp releases do
    [
      llm_lsp_mcp: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            darwin_x64: [os: :darwin, cpu: :x86_64],
            darwin_arm64: [os: :darwin, cpu: :aarch64],
            win_x64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp aliases do
    [
      "deps.get": ["deps.get", "gleam.deps.get"],
      start: ["run -e \":llm_lsp_mcp.main()\""]
    ]
  end
end
