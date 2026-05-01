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
  """

  alias Claudio.APIError

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
end
