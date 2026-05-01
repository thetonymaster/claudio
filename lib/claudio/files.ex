defmodule Claudio.Files do
  @moduledoc """
  Anthropic Files API client.

  Upload files to Anthropic's storage so they can be referenced from message
  content blocks via the `type: "document"` / `source: {type: "file", file_id}`
  shape (see `Claudio.Messages.Request.add_message_with_document/4`).

  ## Beta gating

  The Files API is currently behind the `files-api-2025-04-14` Anthropic beta
  flag. Pass it on the client built by `Claudio.Client.new/2`:

      client = Claudio.Client.new(%{
        token: "sk-ant-...",
        beta: ["files-api-2025-04-14"]
      })

  Or set it globally via application config (applies to every Claudio call):

      config :claudio, :claudio,
        default_beta_features: ["files-api-2025-04-14"]

  ## Example

      {:ok, %{"id" => file_id}} =
        Claudio.Files.upload(client, bytes, content_type: "application/pdf",
          filename: "contract.pdf")

      request =
        Claudio.Messages.Request.new("claude-sonnet-4-6")
        |> Claudio.Messages.Request.add_message_with_document(:user, "Summarise.", file_id)

      Claudio.Messages.create(client, request)

      # List, inspect, and clean up later:
      {:ok, %{"data" => files}} = Claudio.Files.list(client, limit: 50)
      {:ok, _meta} = Claudio.Files.get(client, file_id)
      {:ok, bytes} = Claudio.Files.download(client, file_id)
      {:ok, %{"type" => "file_deleted"}} = Claudio.Files.delete(client, file_id)
  """

  alias Claudio.APIError

  @doc """
  Lists files uploaded to the Anthropic Files API.

  ## Beta gating

  Requires the `files-api-2025-04-14` Anthropic beta flag on the client (see
  moduledoc).

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `opts` — Optional keyword list:
        * `:limit` — Number of files to return (default server-side: 20).
        * `:before_id` — Cursor for the previous page (file id).
        * `:after_id` — Cursor for the next page (file id).

  ## Returns

    * `{:ok, %{"data" => [...], "first_id" => _, "last_id" => _, "has_more" => _}}`
      on success.
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec list(Req.Request.t(), keyword()) :: {:ok, map()} | {:error, APIError.t() | term()}
  def list(client, opts \\ []) do
    query_params = build_query_params(opts)

    case Req.get(client, url: "files", params: query_params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Upload bytes to the Anthropic Files API.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`. Should have the
      `files-api-2025-04-14` beta feature configured (see moduledoc).
    * `bytes` — The raw file contents as a binary.
    * `opts` — Required keyword list:
        * `:content_type` — MIME type (e.g. `"application/pdf"`).
        * `:filename` — Filename string (used for the multipart `filename` part).

  ## Returns

    * `{:ok, %{"id" => "file_xxx", "type" => "file", "filename" => "...",
       "mime_type" => "...", "size_bytes" => N, "created_at" => "..."}}` on success.
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec upload(Req.Request.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, APIError.t() | term()}
  def upload(client, bytes, opts) when is_binary(bytes) and is_list(opts) do
    content_type = Keyword.fetch!(opts, :content_type)
    filename = Keyword.fetch!(opts, :filename)

    # `form_multipart` overrides the client's default `json:` body codec for
    # this single request, which is what we want — the Files API endpoint
    # expects multipart/form-data, not JSON.
    case Req.post(client,
           url: "files",
           form_multipart: [
             file: {bytes, filename: filename, content_type: content_type}
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"id" => _} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves metadata for a single file.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `file_id` — The file id returned from `upload/3` (e.g. `"file_abc123"`).

  ## Returns

    * `{:ok, %{"id" => _, "type" => "file", "filename" => _, "mime_type" => _,
       "size_bytes" => _, "created_at" => _, "downloadable" => _}}` on success.
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec get(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t() | term()}
  def get(client, file_id) when is_binary(file_id) do
    case Req.get(client, url: "files/#{file_id}") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Downloads the raw bytes of a file.

  Req auto-decodes JSON only when `content-type: application/json`; for any
  other content type (PDF, image, plain text, etc.), the response body is
  returned as a raw binary unchanged.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `file_id` — The file id returned from `upload/3`.

  ## Returns

    * `{:ok, binary()}` on success — the raw file contents.
    * `{:error, %Claudio.APIError{}}` on a non-200 response (error bodies are JSON).
    * `{:error, term()}` on a transport/Req error.
  """
  @spec download(Req.Request.t(), String.t()) ::
          {:ok, binary()} | {:error, APIError.t() | term()}
  def download(client, file_id) when is_binary(file_id) do
    case Req.get(client, url: "files/#{file_id}/content") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a file from the Anthropic Files API.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `file_id` — The file id to delete.

  ## Returns

    * `{:ok, %{"id" => _, "type" => "file_deleted"}}` on success.
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec delete(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t() | term()}
  def delete(client, file_id) when is_binary(file_id) do
    case Req.delete(client, url: "files/#{file_id}") do
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
