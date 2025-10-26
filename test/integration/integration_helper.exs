defmodule Claudio.IntegrationHelper do
  @moduledoc """
  Helper functions for integration tests.

  Integration tests require a valid ANTHROPIC_API_KEY environment variable.
  They are excluded by default and must be run explicitly with:

      mix test --only integration

  Or include them with:

      mix test --include integration
  """

  def skip_if_no_api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:skip, "ANTHROPIC_API_KEY not set"}

      "" ->
        {:skip, "ANTHROPIC_API_KEY is empty"}

      _key ->
        :ok
    end
  end

  def create_client do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    Claudio.Client.new(%{
      token: api_key,
      version: "2023-06-01"
    })
  end

  def create_client_with_beta(beta_features) when is_list(beta_features) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    Claudio.Client.new(%{
      token: api_key,
      version: "2023-06-01",
      beta: beta_features
    })
  end

  def test_model, do: "claude-3-5-sonnet-20241022"

  def small_model, do: "claude-3-5-haiku-20241022"
end
