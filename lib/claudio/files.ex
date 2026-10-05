defmodule Claudio.Files do
  @moduledoc """
  Anthropic Files API client.

  Upload files to Anthropic's storage so they can be referenced from message
  content blocks via the `type: "document"` / `source: {type: "file", file_id}`
  shape (see `Claudio.Messages.Request.add_message_with_document/4`).

  ## GA — no beta header

  The Files API is generally available; no `anthropic-beta` header is needed.
  Responses without the header use the GA shapes: `list/2` returns
  `%{"data" => [...], "next_page" => cursor | nil}` and pages with `:page`
  (or fetches up to 100 known ids with `:ids`); `before_id`/`after_id` return 400.

  Callers that still put `files-api-2025-04-14` on their client keep the old
  beta shapes (`has_more`/`first_id`/`last_id`, `:before_id`/`:after_id`
  cursors, no `expires_at`) — Claudio passes whatever you choose through.

  ## Example

      {:ok, %{"id" => file_id}} =
        Claudio.Files.upload(client, bytes, content_type: "application/pdf",
          filename: "contract.pdf")

      request =
        Claudio.Messages.Request.new("claude-opus-5-5")
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

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `opts` — Optional keyword list:
        * `:limit` — Files per page (server default 20, max 1000).
        * `:page` — Cursor from a previous response's `"next_page"`.
        * `:ids` — Up to 100 file ids, sent as repeated `ids[]`; returns a single page.
          Not combinable with `:page`/`:limit` (the API rejects it).
        * `:before_id` / `:after_id` — Legacy cursors; only valid when the client
          sends the `files-api-2025-04-14` beta header.

  ## Returns

    * `{:ok, %{"data" => [...], "next_page" => _}}` (GA) or
      `{:ok, %{"data" => [...], "first_id" => _, "last_id" => _, "has_more" => _}}`
      (with the legacy beta header).
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

  defp expiry_field(opts) do
    case Keyword.fetch(opts, :expires_in_seconds) do
      {:ok, seconds} when is_integer(seconds) ->
        [expires_in_seconds: Integer.to_string(seconds)]

      {:ok, other} ->
        raise ArgumentError,
              "Claudio.Files.upload/3: :expires_in_seconds must be an integer; got #{inspect(other)}"

      :error ->
        []
    end
  end

  @doc """
  Upload bytes to the Anthropic Files API.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `bytes` — The raw file contents as a binary.
    * `opts` — Keyword list. Required:
        * `:content_type` — MIME type (e.g. `"application/pdf"`).
        * `:filename` — Filename string (used for the multipart `filename` part).

    Optional:

        * `:expires_in_seconds` — Integer seconds from upload until the file expires
          (sent as a multipart form field). The API documents a range of 3600 (one hour)
          to 7776000 (ninety days) and rejects other values with a 400. Without it the
          file does not expire.

  ## Returns

    * `{:ok, %{"id" => "file_xxx", "type" => "file", "filename" => "...",
       "mime_type" => "...", "size_bytes" => N, "created_at" => "..."}}` on success.
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec upload(Req.Request.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, APIError.t() | term()}
  def upload(client, bytes, opts) when is_binary(bytes) and is_list(opts) do
    opts =
      Claudio.Options.validate!(
        opts,
        [:content_type, :filename, :expires_in_seconds],
        "Claudio.Files.upload/3"
      )

    content_type =
      case Keyword.fetch(opts, :content_type) do
        {:ok, value} ->
          value

        :error ->
          raise ArgumentError,
                "Claudio.Files.upload/3 requires a :content_type option, " <>
                  "e.g. content_type: \"application/pdf\""
      end

    filename =
      case Keyword.fetch(opts, :filename) do
        {:ok, value} ->
          value

        :error ->
          raise ArgumentError,
                "Claudio.Files.upload/3 requires a :filename option, " <>
                  "e.g. filename: \"contract.pdf\""
      end

    # `form_multipart` overrides the client's default `json:` body codec for
    # this single request, which is what we want — the Files API endpoint
    # expects multipart/form-data, not JSON.
    case Req.post(client,
           url: "files",
           form_multipart:
             expiry_field(opts) ++
               [file: {bytes, filename: filename, content_type: content_type}]
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
    scalars =
      for key <- [:limit, :page, :before_id, :after_id],
          Keyword.get(opts, key) != nil,
          do: {key, Keyword.get(opts, key)}

    scalars ++ ids_params(Keyword.get(opts, :ids))
  end

  defp ids_params(nil), do: []
  defp ids_params(ids) when is_list(ids), do: Enum.map(ids, &{"ids[]", &1})

  defp ids_params(other) do
    raise ArgumentError,
          "Claudio.Files.list/2 :ids must be a list of file ids; got #{inspect(other)}"
  end
end
