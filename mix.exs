defmodule Claudio.MixProject do
  use Mix.Project

  @version "0.1.1"
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
      name: "Claudio",
      source_url: @source_url
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
      {:poison, "~> 6.0"},
      {:bypass, "~> 2.1", only: :test},
      {:plug_cowboy, "~> 2.0", only: :test},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
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
      maintainers: ["Antonio Costa"]
    ]
  end

  defp docs do
    [
      main: "Claudio",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"],
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
        "Core": [
          Claudio.Client,
          Claudio.APIError
        ],
        "Tools": [
          Claudio.Tools
        ]
      ]
    ]
  end
end
