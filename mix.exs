defmodule Claudio.MixProject do
  use Mix.Project

  def project do
    [
      app: :claudio,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:tesla, "~> 1.11"},
      {:poison, "~> 6.0"},
      # optional, required by Mint adapter, recommended
      {:mint, "~> 1.0"},
      {:mox, "~> 1.0", only: :test},
      {:jason, "~> 1.4", only: :test}
    ]
  end
end
