defmodule Claudio.MixProject do
  use Mix.Project

  @version "0.7.0"
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
      {:req, "~> 0.5"},
      {:bypass, "~> 2.1", only: :test},
      {:plug_cowboy, "~> 2.0", only: :test},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    An Elixir client library for the Anthropic API, providing comprehensive support
    for Claude models including Messages API, Batches API, streaming, tool calling,
    prompt caching, and vision capabilities.
    """
  end

  defp package do
    [
      name: "claudio",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
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
      extras: ["README.md", "CHANGELOG.md", "LICENSE", "guides/GETTING_STARTED.md"],
      groups_for_extras: %{
        "Guides" => ["guides/GETTING_STARTED.md"]
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
        Tools: [
          Claudio.Tools
        ],
        Agent: [
          Claudio.Agent
        ]
      ]
    ]
  end
end
