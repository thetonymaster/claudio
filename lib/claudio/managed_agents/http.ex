defmodule Claudio.ManagedAgents.HTTP do
  @moduledoc false
  # Transport shared by the Managed Agents modules: per-request beta, bracketed query
  # encoding, id path segments, APIError mapping.

  alias Claudio.APIError
  alias Claudio.Client
  alias Claudio.ManagedAgents

  @beta "managed-agents-2026-04-01"

  @doc false
  def beta, do: @beta

  @doc false
  # Non-empty, and not a dot segment: "." and ".." are unreserved, so segment/1 leaves them
  # as-is, and any hop that normalises paths would turn `resources/..` into the parent.
  defguard is_id(id) when is_binary(id) and id not in ["", ".", ".."]

  @spec get(Req.Request.t(), String.t(), keyword()) :: ManagedAgents.result()
  def get(client, path, opts) when is_list(opts),
    do: client |> with_beta() |> Req.get(url: path, params: encode_query(opts)) |> handle()

  @spec post(Req.Request.t(), String.t(), map() | nil) :: ManagedAgents.result()
  def post(client, path, nil), do: client |> with_beta() |> Req.post(url: path) |> handle()

  def post(client, path, body) when is_map(body),
    do: client |> with_beta() |> Req.post(url: path, json: body) |> handle()

  @spec delete(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def delete(client, path), do: client |> with_beta() |> Req.delete(url: path) |> handle()

  @doc false
  # One path segment: everything outside RFC 3986's unreserved set is percent-escaped, so an
  # id can never reach another endpoint ("a/b" -> "a%2Fb").
  @spec segment(String.t()) :: String.t()
  def segment(id) when is_id(id), do: URI.encode(id, &URI.char_unreserved?/1)

  @doc false
  # [statuses: ["idle"], created_at: [gte: dt], limit: 5]
  #   -> [{"statuses[]", "idle"}, {"created_at[gte]", "2026-...Z"}, {"limit", "5"}]
  @spec encode_query(keyword()) :: [{String.t(), String.t()}]
  def encode_query(opts) when is_list(opts), do: Enum.flat_map(opts, &encode_option/1)

  # `[_ | _]` matches only non-empty lists: `[]` falls through to scalar!/2 and raises there.
  defp encode_option({key, [_ | _] = value}) do
    if Keyword.keyword?(value) do
      Enum.map(value, fn {sub, v} -> {"#{key}[#{sub}]", scalar!(key, v)} end)
    else
      Enum.map(value, fn v -> {"#{key}[]", scalar!(key, v)} end)
    end
  end

  defp encode_option({key, value}), do: [{to_string(key), scalar!(key, value)}]

  defp scalar!(_key, %DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp scalar!(_key, v) when is_binary(v), do: v
  defp scalar!(_key, v) when is_integer(v), do: Integer.to_string(v)
  defp scalar!(_key, v) when is_boolean(v), do: Atom.to_string(v)
  defp scalar!(_key, v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)

  defp scalar!(key, v) do
    raise ArgumentError,
          "Claudio.ManagedAgents query option #{inspect(key)} must be a string, integer, " <>
            "boolean, atom or DateTime (or a non-empty list / keyword list of those); " <>
            "got: #{inspect(v)}"
  end

  defp with_beta(client), do: Client.with_betas(client, [@beta])

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, APIError.from_response(status, body)}

  defp handle({:error, reason}), do: {:error, reason}
end
