defmodule Claudio.MixProject do
  use Mix.Project

  @version "0.7.1"
  @source_url "https://github.com/thetonymaster/claudio"

  def project do
    [
      app: :claudio,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      dialyzer: [plt_core_path: "_build/plts"],
      # cowlib is test-only (Bypass -> plug_cowboy -> cowboy). 43966 and 43969 have no fix in
      # any release; 43971 is fixed in 2.20.0, which is pinned out (see deps/0: OTP 26).
      # Hex warns once an entry no longer matches the lock.
      hex: [
        ignore_advisories: ["EEF-CVE-2026-43966", "EEF-CVE-2026-43969", "EEF-CVE-2026-43971"]
      ],
      name: "Claudio",
      source_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # >= 0.6.1: earlier releases carry EEF-CVE-2026-49755 (decompression bomb, fixed in
      # 0.6.1) and EEF-CVE-2026-49756 (multipart header injection, fixed in 0.6.0), which
      # Files/Skills multipart uploads would reach.
      {:req, "~> 0.6 and >= 0.6.1"},
      {:bypass, "~> 2.1", only: :test},
      {:plug_cowboy, "~> 2.0", only: :test},
      # Bypass's server. cowlib 2.20.0 uses `maybe` without enabling the feature, so it
      # fails to compile on OTP 26, which CI still tests. Lift these pins when OTP 26 leaves
      # the matrix.
      {:cowboy, "~> 2.18.0", only: :test},
      {:cowlib, "~> 2.19.0", only: :test},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Elixir client for the Anthropic Claude API: Messages (streaming, tools, prompt caching,
    vision, PDFs, thinking, structured outputs), Batches, Files, Models, Skills, Admin,
    Managed Agents (beta), MCP and A2A, with :telemetry events ready for OpenTelemetry.
    """
  end

  defp package do
    [
      name: "claudio",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/claudio/changelog.html",
        "Anthropic API Docs" => "https://docs.anthropic.com/"
      },
      maintainers: ["Antonio Cabrera"]
    ]
  end

  defp docs do
    [
      main: "Claudio",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "guides/GETTING_STARTED.md",
        "guides/telemetry.md"
      ],
      groups_for_extras: %{
        "Guides" => ["guides/GETTING_STARTED.md", "guides/telemetry.md"]
      },
      groups_for_modules: [
        "Messages API": [
          Claudio.Messages,
          Claudio.Messages.Request,
          Claudio.Messages.Response,
          Claudio.Messages.Stream
        ],
        "Batches API": [
          Claudio.Batches
        ],
        Core: [
          Claudio,
          Claudio.Client,
          Claudio.APIError
        ],
        "Files API": [
          Claudio.Files
        ],
        "Models API": [
          Claudio.Models
        ],
        "Admin API": [
          Claudio.Admin
        ],
        "Skills API": [
          Claudio.Skills
        ],
        "Managed Agents (beta)": [
          Claudio.ManagedAgents,
          Claudio.ManagedAgents.Agents,
          Claudio.ManagedAgents.Environments,
          Claudio.ManagedAgents.Sessions
        ],
        Tools: [
          Claudio.Tools
        ],
        Agent: [
          Claudio.Agent
        ],
        MCP: [~r/^Claudio\.MCP/],
        A2A: [~r/^Claudio\.A2A/]
      ]
    ]
  end
end
