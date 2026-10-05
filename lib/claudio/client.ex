defmodule Claudio.Client do
  @moduledoc """
  HTTP client for the Anthropic API using Req.

  This module provides HTTP client functionality for interacting with the Anthropic API.
  It handles authentication, versioning, beta features, and configurable timeouts.

  ## Configuration

  Pass HTTP options per client, so different clients in one application can behave
  differently (say, retries for batch polling but none for one-shot creates):

      client = Claudio.Client.new(%{
        token: "your-api-key",
        timeout: 60_000,        # Connection timeout in ms (default: 60s)
        recv_timeout: 120_000,  # Receive timeout in ms (default: 120s)
        retry: true
      })

  Each key given to `new/2` wins. Keys you leave out, or pass as `nil`, fall back to
  the application environment, then to the built-in defaults:

      # config/config.exs
      config :claudio,
        default_api_version: "2023-06-01",
        default_beta_features: []

      config :claudio, Claudio.Client,
        timeout: 60_000,
        recv_timeout: 120_000,
        retry: true

  ### Timeouts

  `timeout` controls connection establishment; `recv_timeout` controls how long to
  wait for data once connected. For long streaming operations, raise `recv_timeout`
  (e.g. `recv_timeout: 600_000` for 10 minutes). Both take a non-negative integer (ms)
  or `:infinity`; anything else raises `ArgumentError` when the client is built.

  ### Retries

  `retry:` retries transient failures — HTTP 408, 429, 500, 502, 503, 504, 529
  (overloaded) and connection timeouts/refusals — on every method, including the POSTs
  the Messages API uses:

    * `retry: true` — 3 retries; honours Retry-After (integer seconds) on 429, 503 and 529, else backs off 1s, 2s, 4s
    * `retry: [delay: 1000, max_retries: 3, max_delay: 10_000]` — delay doubles per
      attempt, capped at `max_delay` (all in ms); Retry-After still wins when the server
      sends it
    * `retry: false` — no retries at all (not even Req's GET/HEAD default)

  Without `retry:` (unset or `nil` at every level), Req's default applies: only GET/HEAD
  requests are retried. Any
  other value, or an unknown key in the keyword list, raises `ArgumentError`.
  Streaming requests are never retried.

  Retries can duplicate work. After an ambiguous failure — a timeout, a closed connection,
  a 5xx — the API may already have processed the request, and the retry sends it again:
  a second message is generated and billed, and a create call (a batch, a file upload,
  an Admin invite) can run twice. None of these endpoints take an idempotency key, so
  set `retry: false` where a duplicate is unacceptable. After an ambiguous failure,
  retry only if your application can deduplicate requests or reconcile the outcome.

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

      # With beta features (per-feature betas are normally declared by the
      # `Claudio.Messages.Request` helpers; set them here only for ad-hoc flags)
      client = Claudio.Client.new(%{
        token: "your-api-key",
        version: "2023-06-01",
        beta: ["context-management-2025-06-27"]
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
  @config_keys [:token, :version, :beta, :auth_type, :timeout, :recv_timeout, :retry, :finch]

  @doc """
  Creates a new HTTP client for the Anthropic API.

  ## Parameters

    * `config` - Configuration map or keyword list with the following keys (any other key
      raises `ArgumentError`):
      * `:token` (required) - Your Anthropic API key; a non-empty string, else `ArgumentError`
      * `:version` (optional) - API version string (default: "2023-06-01")
      * `:beta` (optional) - List of beta feature flags
      * `:auth_type` (optional) - `:api_key` (default) or `:bearer`
      * `:timeout` (optional) - Connection timeout in ms or `:infinity` (default: 60_000)
      * `:recv_timeout` (optional) - Receive timeout in ms or `:infinity` (default: 120_000)
      * `:retry` (optional) - `true`, `false`, or `[delay:, max_retries:, max_delay:]`;
        see "Retries" in the module docs
    * `endpoint` (optional) - API endpoint URL (default: "https://api.anthropic.com/v1/")

  ## Returns

  Returns a `Req.Request` struct configured for Anthropic API calls. Requests made with it emit
  `[:claudio, :http, :request, :start | :stop]` per attempt. See the [telemetry guide](telemetry.html).

  ## Examples

      # Basic client
      iex> client = Claudio.Client.new(%{token: "sk-ant-..."})
      %Req.Request{...}

      # With beta features (normally declared by the `Request` helpers instead)
      iex> client = Claudio.Client.new(%{
      ...>   token: "sk-ant-...",
      ...>   version: "2023-06-01",
      ...>   beta: ["context-management-2025-06-27"]
      ...> })
      %Req.Request{...}

  """
  @spec new(map() | keyword(), String.t()) :: Req.Request.t()
  def new(config, endpoint \\ "https://api.anthropic.com/v1/")

  def new(config, endpoint) when is_list(config), do: new(Map.new(config), endpoint)

  def new(config, endpoint) when is_map(config) do
    config
    |> Map.to_list()
    |> Claudio.Options.validate!(@config_keys, "Claudio.Client.new/2")

    case Map.get(config, :token) do
      token when is_binary(token) and token != "" ->
        :ok

      other ->
        raise ArgumentError,
              "Claudio.Client.new/2 :token must be a non-empty string; got #{inspect(other)} " <>
                "(if you read it from the environment, is ANTHROPIC_API_KEY set?)"
    end

    config |> merge_defaults() |> build_request(endpoint)
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

    default_version = Keyword.get(app_config, :default_api_version, @default_api_version)

    config
    |> Map.update(:version, default_version, &(&1 || default_version))
    |> maybe_add_default_beta(app_config)
  end

  defp maybe_add_default_beta(config, app_config) do
    case {Map.get(config, :beta), Keyword.get(app_config, :default_beta_features)} do
      {nil, beta} when is_list(beta) and beta != [] -> Map.put(config, :beta, beta)
      _ -> config
    end
  end

  defp build_request(auth, endpoint) do
    env = config()
    timeout = validate_timeout!(:timeout, setting(auth, env, :timeout, 60_000))
    recv_timeout = validate_timeout!(:recv_timeout, setting(auth, env, :recv_timeout, 120_000))
    retry_opts = auth |> setting(env, :retry, nil) |> normalize_retry!()

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

    (opts ++ req_retry_options(retry_opts))
    |> Req.new()
    |> Claudio.Telemetry.attach_http()
  end

  # Maps the documented `retry:` config onto Req's retry step. Req's own default only
  # retries GET/HEAD, and every Messages call is a POST, so without this nothing retries.
  defp req_retry_options(nil), do: []
  defp req_retry_options(:disabled), do: [retry: false]

  defp req_retry_options(opts) do
    [
      retry: fn request, response_or_exception ->
        retry_decision(request, response_or_exception, opts)
      end,
      max_retries: Keyword.get(opts, :max_retries, 3)
    ]
  end

  @retry_after_statuses [429, 503, 529]

  # Req only reads Retry-After on 429/503 and ignores it when `:retry_delay` is set, so
  # Claudio computes every delay itself: the server's Retry-After (integer seconds) on
  # 429/503/529, else the backoff. `:retry_delay` must stay unset or Req raises.
  defp retry_decision(request, response_or_exception, opts) do
    if retryable?(request, response_or_exception) do
      attempt = Req.Request.get_private(request, :req_retry_count, 0)
      {:delay, retry_after_ms(response_or_exception) || backoff_ms(attempt, opts)}
    else
      false
    end
  end

  # HTTP-date or unparseable values fall back to the backoff.
  defp retry_after_ms(%Req.Response{status: status} = response)
       when status in @retry_after_statuses do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds * 1000
    else
      _ -> nil
    end
  end

  defp retry_after_ms(_other), do: nil

  # Unset `delay:` mirrors Req's default schedule (1s, 2s, 4s, ...) minus its jitter.
  defp backoff_ms(attempt, opts) do
    case Keyword.get(opts, :delay) do
      nil -> 1000 * Integer.pow(2, attempt)
      delay -> min(delay * Integer.pow(2, attempt), Keyword.get(opts, :max_delay, 10_000))
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

  # A key given to new/2 wins over `config :claudio, Claudio.Client`, which wins over
  # the built-in default. `nil` counts as not given at either level, so passing through
  # an absent option (`retry: opts[:retry]`) cannot silently override the app config.
  defp setting(auth, env, key, default) do
    case Map.get(auth, key) do
      nil ->
        case Keyword.get(env, key) do
          nil -> default
          value -> value
        end

      value ->
        value
    end
  end

  defp validate_timeout!(_key, :infinity), do: :infinity
  defp validate_timeout!(_key, ms) when is_integer(ms) and ms >= 0, do: ms

  defp validate_timeout!(key, other) do
    raise ArgumentError,
          "Claudio.Client.new/2 #{inspect(key)} must be a non-negative integer (ms) or " <>
            ":infinity; got #{inspect(other)}"
  end

  @retry_keys [:delay, :max_retries, :max_delay]

  defp normalize_retry!(nil), do: nil
  defp normalize_retry!(true), do: []
  defp normalize_retry!(false), do: :disabled

  defp normalize_retry!(opts) when is_list(opts) do
    opts = Claudio.Options.validate!(opts, @retry_keys, "Claudio.Client.new/2 :retry")

    Enum.each(opts, fn
      {_key, value} when is_integer(value) and value >= 0 ->
        :ok

      {key, value} ->
        raise ArgumentError,
              "Claudio.Client.new/2 :retry #{inspect(key)} must be a non-negative integer" <>
                "#{if key == :max_retries, do: "", else: " (ms)"}; got #{inspect(value)}"
    end)

    opts
  end

  defp normalize_retry!(other) do
    raise ArgumentError,
          "Claudio.Client.new/2 :retry must be true, false, or a keyword list of " <>
            ":delay, :max_retries, :max_delay; got #{inspect(other)}"
  end

  defp config do
    Application.get_env(:claudio, __MODULE__, [])
  end
end
