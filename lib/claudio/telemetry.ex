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
  @spec usage(term()) :: map()
  def usage(usage) when is_map(usage) do
    @token_keys
    |> Enum.reduce(%{}, fn key, acc -> put_present(acc, key, get(usage, key)) end)
    |> put_present(:thinking_tokens, thinking_tokens(usage))
  end

  def usage(_usage), do: %{}

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
  def error_type(%Claudio.APIError{type: type}) when is_atom(type) or is_binary(type), do: type

  def error_type(%{__exception__: true, reason: reason})
      when is_atom(reason) and reason not in [nil, true, false],
      do: reason

  def error_type(%{__exception__: true, __struct__: module}), do: module
  def error_type(_other), do: :unknown

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
  @spec server_address(Req.Request.t()) :: String.t() | nil
  def server_address(%Req.Request{options: options}) do
    case options[:base_url] do
      url when is_binary(url) -> URI.parse(url).host
      _ -> nil
    end
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

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
