defmodule Claudio.Models do
  @moduledoc """
  Anthropic Models API client.

  Discover available Claude models and their capabilities at runtime. GA — no
  beta header required.

  ## Example

      client = Claudio.Client.new(%{token: "sk-ant-...", version: "2023-06-01"})

      {:ok, %{"data" => models}} = Claudio.Models.list(client, limit: 20)
      {:ok, model} = Claudio.Models.get(client, "claude-opus-4-8")
  """

  alias Claudio.APIError

  @doc """
  Lists available models (most recently released first), paginated.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `opts` — Optional keyword list:
        * `:limit` — Number of models to return (default server-side: 20).
        * `:before_id` — Cursor for the previous page (model id).
        * `:after_id` — Cursor for the next page (model id).

  ## Returns

    * `{:ok, %{"data" => [...], "first_id" => _, "last_id" => _, "has_more" => _}}`
      on success.
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec list(Req.Request.t(), keyword()) :: {:ok, map()} | {:error, APIError.t() | term()}
  def list(client, opts \\ []) do
    query_params = build_query_params(opts)

    case Req.get(client, url: "models", params: query_params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves a single model by id or alias.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `model_id` — A model id or alias (e.g. `"claude-opus-4-8"`).

  ## Returns

    * `{:ok, %{"id" => _, "type" => "model", "display_name" => _, "created_at" => _}}`
      on success (may also include `max_input_tokens` / `max_tokens` / `capabilities`).
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec get(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t() | term()}
  def get(client, model_id) when is_binary(model_id) do
    case Req.get(client, url: "models/#{model_id}") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_query_params(opts) do
    []
    |> maybe_add_param(:limit, Keyword.get(opts, :limit))
    |> maybe_add_param(:before_id, Keyword.get(opts, :before_id))
    |> maybe_add_param(:after_id, Keyword.get(opts, :after_id))
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]
end
