defmodule Claudio.Client do
  @moduledoc """
  HTTP client for the Anthropic API using Req.

  This module provides HTTP client functionality for interacting with the Anthropic API.
  It handles authentication, versioning, beta features, and configurable timeouts.

  ## Configuration

  You can configure default values and HTTP options in your config file:

      # config/config.exs
      config :claudio,
        default_api_version: "2023-06-01",
        default_beta_features: []

      config :claudio, Claudio.Client,
        timeout: 60_000,        # Connection timeout in ms (default: 60s)
        recv_timeout: 120_000   # Receive timeout in ms (default: 120s)

  ### Timeout Configuration

  The `timeout` option controls the connection establishment timeout, while
  `recv_timeout` controls how long to wait for data once connected. For
  streaming operations, you may want to increase `recv_timeout`:

      # For long-running streaming operations
      config :claudio, Claudio.Client,
        timeout: 60_000,
        recv_timeout: 600_000   # 10 minutes

  ### Retry Configuration

  Enable automatic retries for transient failures — HTTP 408, 429, 500, 502, 503, 504,
  529 (overloaded) and connection timeouts/refusals — on every method, including the
  POSTs the Messages API uses:

      config :claudio, Claudio.Client,
        retry: true  # 3 retries; Retry-After on 429/503, else backs off 1s, 2s, 4s

      # Or customize (delay doubles per attempt, capped at max_delay; all in ms):
      config :claudio, Claudio.Client,
        retry: [
          delay: 1000,
          max_retries: 3,
          max_delay: 10_000
        ]

  Without `retry:`, Req's default applies: only GET/HEAD requests are retried.
  `retry: false` disables retries entirely. Streaming requests are never retried.

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

      # Custom endpoint (for testing or proxies)
      client = Claudio.Client.new(
        %{token: "key", version: "2023-06-01"},
        "https://custom.api.endpoint/v1/"
      )

  ## Return Value

  Returns a `Req.Request` struct that can be used with `Claudio.Messages`,
  `Claudio.Batches`, and other API modules.
  """

  @default_api_version "2023-06-01"

  @doc """
  Creates a new HTTP client for the Anthropic API.

  ## Parameters

    * `config` - Configuration map with the following keys:
      * `:token` (required) - Your Anthropic API key
      * `:version` (optional) - API version string (default: "2023-06-01")
      * `:beta` (optional) - List of beta feature flags
    * `endpoint` (optional) - API endpoint URL (default: "https://api.anthropic.com/v1/")

  ## Returns

  Returns a `Req.Request` struct configured for Anthropic API calls.

  ## Examples

      # Basic client
      iex> client = Claudio.Client.new(%{token: "sk-ant-..."})
      %Req.Request{...}

      # With beta features
      iex> client = Claudio.Client.new(%{
      ...>   token: "sk-ant-...",
      ...>   version: "2023-06-01",
      ...>   beta: ["prompt-caching-2024-07-31"]
      ...> })
      %Req.Request{...}

  """
  @spec new(map(), String.t()) :: Req.Request.t()
  def new(config, endpoint \\ "https://api.anthropic.com/v1/") do
    config = merge_defaults(config)
    build_request(config, endpoint)
  end

  @doc """
  Merges additional beta feature flags into a client's `anthropic-beta` header.

  Unions `betas` with whatever the client was built with at `new/2` (deduped,
  insertion order preserved). Blank and whitespace-only entries are trimmed and
  dropped before merging; an empty list (or one that normalizes to empty)
  returns the client unchanged. Used by the send path to attach per-request
  betas declared via `Claudio.Messages.Request.add_beta/2`.
  """
  @spec with_betas(Req.Request.t(), [String.t()]) :: Req.Request.t()
  def with_betas(client, []), do: client

  def with_betas(client, betas) when is_list(betas) do
    normalized =
      betas
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    existing =
      client
      |> Req.Request.get_header("anthropic-beta")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.uniq(existing ++ normalized) do
      [] -> client
      merged -> Req.Request.put_header(client, "anthropic-beta", Enum.join(merged, ","))
    end
  end

  # Documented form: `config :claudio, default_api_version: ..., default_beta_features: [...]`.
  # The older nested `config :claudio, :claudio, ...` form is still read as a fallback.
  defp merge_defaults(config) do
    nested = Application.get_env(:claudio, :claudio, [])

    app_config =
      Enum.reduce([:default_api_version, :default_beta_features], nested, fn key, acc ->
        case Application.get_env(:claudio, key) do
          nil -> acc
          value -> Keyword.put(acc, key, value)
        end
      end)

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

    opts = [
      base_url: endpoint,
      headers: get_headers(auth),
      receive_timeout: recv_timeout,
      connect_options: [timeout: timeout]
    ]

    opts =
      case Map.get(auth, :finch) do
        nil -> opts
        finch -> [{:finch, finch} | Keyword.delete(opts, :connect_options)]
      end

    Req.new(opts ++ req_retry_options(retry_opts))
  end

  # Maps the documented `retry:` config onto Req's retry step. Req's own default only
  # retries GET/HEAD, and every Messages call is a POST, so without this nothing retries.
  defp req_retry_options(nil), do: []
  defp req_retry_options(:disabled), do: [retry: false]

  defp req_retry_options(opts) do
    [retry: &retryable?/2, max_retries: Keyword.get(opts, :max_retries, 3)] ++
      case Keyword.get(opts, :delay) do
        # Unset: Req honours Retry-After on 429/503, else backs off 1s, 2s, 4s, ...
        nil ->
          []

        delay ->
          max_delay = Keyword.get(opts, :max_delay, 10_000)
          [retry_delay: fn attempt -> min(delay * Integer.pow(2, attempt), max_delay) end]
      end
  end

  @retryable_statuses [408, 429, 500, 502, 503, 504, 529]

  @doc false
  # Retry transient failures on any method: rate limits, 5xx, 529 overloaded, and
  # connection-level errors.
  def retryable?(_request, %Req.Response{status: status}), do: status in @retryable_statuses

  def retryable?(_request, %Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  def retryable?(_request, _other), do: false

  defp get_headers(auth) do
    %{token: token, version: version} = auth

    headers = [
      {"user-agent", "claudio"},
      {"anthropic-version", version},
      auth_header(auth, token)
    ]

    case auth do
      %{beta: beta} when is_list(beta) and beta != [] ->
        [{"anthropic-beta", Enum.join(beta, ",")} | headers]

      _ ->
        headers
    end
  end

  # Authentication header: `x-api-key` by default, or `Authorization: Bearer`
  # when the client is built with `auth_type: :bearer` (OAuth / Workload
  # Identity Federation tokens). The same `:token` field carries the credential.
  defp auth_header(%{auth_type: :bearer}, token), do: {"authorization", "Bearer #{token}"}
  defp auth_header(_auth, token), do: {"x-api-key", token}

  defp get_timeout_config do
    client_config = config()
    timeout = Keyword.get(client_config, :timeout, 60_000)
    recv_timeout = Keyword.get(client_config, :recv_timeout, 120_000)

    {timeout, recv_timeout}
  end

  defp get_retry_config do
    case Keyword.get(config(), :retry) do
      true -> []
      false -> :disabled
      retry_opts when is_list(retry_opts) -> retry_opts
      _ -> nil
    end
  end

  defp config do
    Application.get_env(:claudio, __MODULE__, [])
  end
end
