defmodule Claudio.Telemetry do
  @moduledoc false
  # Shared mappings for Claudio's :telemetry events (see guides/telemetry.md). Holds no state and
  # attaches no handlers.

  @token_keys [
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens
  ]
  @request_keys [:max_tokens, :temperature, :top_p, :top_k]

  @doc false
  # Token counts from a usage map (atom or string keys). Used as both measurements and metadata.
  # A token is kept only when it is a non-negative integer.
  @spec usage(term()) :: map()
  def usage(usage) when is_map(usage) do
    @token_keys
    |> Enum.reduce(%{}, fn key, acc -> put_token(acc, key, get(usage, key)) end)
    |> put_token(:thinking_tokens, thinking_tokens(usage))
  end

  def usage(_usage), do: %{}

  defp put_token(map, key, value) when is_integer(value) and value >= 0,
    do: Map.put(map, key, value)

  defp put_token(map, _key, _value), do: map

  # usage.output_tokens_details is carried raw (atom or string keys).
  defp thinking_tokens(usage) do
    case get(usage, :output_tokens_details) do
      %{} = details -> get(details, :thinking_tokens)
      _ -> nil
    end
  end

  @doc false
  # A bounded error classification, safe to use as OTel `error.type`.
  @spec error_type(term()) :: atom() | String.t()
  def error_type(%Claudio.APIError{type: type})
      when is_atom(type) and type not in [nil, true, false],
      do: type

  def error_type(%Claudio.APIError{type: type}) when is_binary(type),
    do: bounded_type(type) || :unknown

  def error_type(%Claudio.APIError{}), do: :unknown

  def error_type(%{__exception__: true, reason: reason})
      when is_atom(reason) and reason not in [nil, true, false],
      do: reason

  def error_type(%{__exception__: true, __struct__: module}), do: module
  def error_type(_other), do: :unknown

  @doc false
  # A server-supplied error type string, only when it looks like an identifier (bounded
  # cardinality, no free text); nil otherwise.
  @spec bounded_type(String.t()) :: String.t() | nil
  def bounded_type(type) when is_binary(type) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, type), do: type
  end

  @doc false
  @spec request_metadata(map()) :: map()
  def request_metadata(payload) when is_map(payload) do
    base =
      Enum.reduce(@request_keys, %{}, fn key, acc -> put_present(acc, key, get(payload, key)) end)

    effort =
      case get(payload, :output_config) do
        %{} = output_config -> get(output_config, :effort)
        _ -> nil
      end

    put_present(base, :effort, effort)
  end

  @doc false
  @spec server_address(term()) :: String.t() | nil
  def server_address(%Req.Request{options: options}) do
    case options[:base_url] do
      url when is_binary(url) -> URI.parse(url).host
      %URI{host: host} -> host
      _ -> nil
    end
  end

  # Req accepts a keyword list or URL as a "client"; those carry no base_url to report.
  def server_address(_client), do: nil

  @doc false
  # The base_url's port, with the scheme default (443 / 80) when it names none.
  @spec server_port(term()) :: :inet.port_number() | nil
  def server_port(%Req.Request{options: options}) do
    case options[:base_url] do
      url when is_binary(url) -> URI.parse(url).port
      %URI{port: port} -> port
      _ -> nil
    end
  end

  def server_port(_client), do: nil

  @doc false
  # server_address and server_port of a client, only those present.
  @spec server_metadata(term()) :: map()
  def server_metadata(client) do
    %{}
    |> put_present(:server_address, server_address(client))
    |> put_present(:server_port, server_port(client))
  end

  @doc false
  @spec request_id(Req.Response.t()) :: String.t() | nil
  def request_id(%Req.Response{} = response) do
    case Req.Response.get_header(response, "request-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  @doc false
  @spec put_present(map(), atom(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  # Per-attempt [:claudio, :http, :request] :start/:stop events. The request step is appended
  # (it runs right before the adapter, after :put_base_url); the response/error steps are
  # prepended so they run before Req's :retry step, which runs the next attempt inside itself.
  @spec attach_http(Req.Request.t()) :: Req.Request.t()
  def attach_http(%Req.Request{} = request) do
    request
    |> Req.Request.append_request_steps(claudio_telemetry: &http_start/1)
    |> Req.Request.prepend_response_steps(claudio_telemetry: &http_stop/1)
    |> Req.Request.prepend_error_steps(claudio_telemetry: &http_stop/1)
  end

  defp http_start(%Req.Request{} = request) do
    start = System.monotonic_time()

    metadata = %{
      method: request.method,
      url: URI.to_string(%{request.url | query: nil, userinfo: nil, fragment: nil}),
      attempt: Req.Request.get_private(request, :req_retry_count, 0),
      telemetry_span_context: make_ref()
    }

    :telemetry.execute(
      [:claudio, :http, :request, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      metadata
    )

    Req.Request.put_private(request, :claudio_http, {start, metadata})
  end

  defp http_stop({request, response_or_exception}) do
    case Req.Request.get_private(request, :claudio_http) do
      {start, metadata} ->
        stop = System.monotonic_time()

        :telemetry.execute(
          [:claudio, :http, :request, :stop],
          %{duration: stop - start, monotonic_time: stop},
          Map.merge(metadata, http_result(response_or_exception))
        )

      nil ->
        :ok
    end

    # Clear so a response step that turns the response into an error (decode_body, ...) and
    # hands off to the error steps does not emit a second :stop for the same attempt.
    {Req.Request.put_private(request, :claudio_http, nil), response_or_exception}
  end

  defp http_result(%Req.Response{status: status} = response),
    do: put_present(%{status_code: status}, :request_id, request_id(response))

  defp http_result(exception), do: %{status_code: nil, error_type: error_type(exception)}

  # The atom key wins when present (even as false or nil); the string key is only a fallback.
  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
