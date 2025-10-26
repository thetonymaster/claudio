defmodule Claudio.Client do
  @moduledoc """
  HTTP client for the Anthropic API using Req.

  ## Configuration

  You can configure default values and HTTP options in your config file:

      # config/config.exs
      config :claudio,
        default_api_version: "2023-06-01",
        default_beta_features: []

      config :claudio, Claudio.Client,
        timeout: 60_000,
        recv_timeout: 120_000

  ## Usage

      # Simple client with defaults
      client = Claudio.Client.new(%{
        token: "your-api-key"
      })

      # With explicit version
      client = Claudio.Client.new(%{
        token: "your-api-key",
        version: "2023-06-01"
      })

      # With beta features
      client = Claudio.Client.new(%{
        token: "your-api-key",
        version: "2023-06-01",
        beta: ["prompt-caching-2024-07-31"]
      })

      # Custom endpoint
      client = Claudio.Client.new(
        %{token: "key", version: "2023-06-01"},
        "https://custom.api.endpoint/v1/"
      )
  """

  @default_api_version "2023-06-01"

  @spec new(map(), String.t()) :: Req.Request.t()
  def new(config, endpoint \\ "https://api.anthropic.com/v1/") do
    config = merge_defaults(config)
    build_request(config, endpoint)
  end

  defp merge_defaults(config) do
    app_config = Application.get_env(:claudio, :claudio, [])

    config
    |> Map.put_new(:version, Keyword.get(app_config, :default_api_version, @default_api_version))
    |> maybe_add_default_beta(app_config)
  end

  defp maybe_add_default_beta(config, app_config) do
    case {Map.get(config, :beta), Keyword.get(app_config, :default_beta_features)} do
      {nil, beta} when is_list(beta) and beta != [] -> Map.put(config, :beta, beta)
      _ -> config
    end
  end

  defp build_request(auth, endpoint) do
    {timeout, recv_timeout} = get_timeout_config()
    retry_opts = get_retry_config()

    req =
      Req.new(
        base_url: endpoint,
        headers: get_headers(auth),
        json: Poison,
        receive_timeout: recv_timeout,
        connect_options: [timeout: timeout]
      )

    if retry_opts do
      Req.Request.prepend_request_steps(req, retry: &apply_retry(&1, retry_opts))
    else
      req
    end
  end

  defp get_headers(auth) do
    %{token: token, version: version} = auth

    headers = [
      {"user-agent", "claudio"},
      {"anthropic-version", version},
      {"x-api-key", token}
    ]

    case auth do
      %{beta: beta} when is_list(beta) and beta != [] ->
        [{"anthropic-beta", Enum.join(beta, ",")} | headers]

      _ ->
        headers
    end
  end

  defp get_timeout_config do
    client_config = config()
    timeout = Keyword.get(client_config, :timeout, 60_000)
    recv_timeout = Keyword.get(client_config, :recv_timeout, 120_000)

    {timeout, recv_timeout}
  end

  defp get_retry_config do
    client_config = config()

    case Keyword.get(client_config, :retry) do
      true ->
        [
          delay: 1000,
          max_retries: 3,
          max_delay: 10_000,
          should_retry: fn
            {:ok, %{status: status}} when status in [429, 500, 502, 503, 504] -> true
            {:ok, _} -> false
            {:error, _} -> true
          end
        ]

      retry_opts when is_list(retry_opts) ->
        retry_opts

      _ ->
        nil
    end
  end

  defp apply_retry(request, _opts) do
    # Req has built-in retry support, this is a placeholder
    # We'll use Req's retry: :transient option in the actual request
    request
  end

  defp config do
    Application.get_env(:claudio, __MODULE__, [])
  end
end
