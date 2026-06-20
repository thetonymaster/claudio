defmodule Claudio.Skills do
  @moduledoc """
  Anthropic **Agent Skills API** client (`/v1/skills`) — manage custom skills
  (packaged `SKILL.md` + files) and their versions.

  **Beta.** Every request carries `anthropic-beta: skills-2025-10-02`, attached
  automatically (via `Claudio.Client.with_betas/2`) — you do not need to build
  the client with it.

      client = Claudio.Client.new(%{token: "sk-ant-...", version: "2023-06-01"})
      {:ok, %{"data" => skills}} = Claudio.Skills.list(client, source: "custom")

  Returns the raw decoded body (`{:ok, map()}`); a non-2xx response maps to
  `{:error, %Claudio.APIError{}}`, consistent with `Claudio.Admin` / `Claudio.Models`.

  ## Creating skills (multipart)

  `create/2` and `create_version/3` upload multipart/form-data. The exact
  form-field names are part of the upload spec; supply a `form_multipart`-shaped
  list (same shape `Claudio.Files.upload/3` uses):

      form = [file: {File.read!("skill.zip"), filename: "skill.zip", content_type: "application/zip"}]
      {:ok, skill} = Claudio.Skills.create(client, form)

  > Prompt-tools (`/v1/experimental/*`) are intentionally **not** implemented —
  > experimental, access-gated, and the beta header is unverified.
  """

  alias Claudio.{APIError, Client}

  @beta "skills-2025-10-02"

  @type result :: {:ok, map()} | {:error, APIError.t() | term()}

  @doc "Lists skills. Opts (`:limit`/`:page`/`:source`) become query params."
  @spec list(Req.Request.t(), keyword()) :: result()
  def list(client, opts \\ []), do: http_get(client, "skills", opts)

  @doc "Retrieves a single skill by id."
  @spec get(Req.Request.t(), String.t()) :: result()
  def get(client, skill_id), do: http_get(client, "skills/#{skill_id}", [])

  @doc "Deletes a skill by id."
  @spec delete(Req.Request.t(), String.t()) :: result()
  def delete(client, skill_id), do: http_delete(client, "skills/#{skill_id}")

  @doc "Lists a skill's versions. Opts become query params."
  @spec list_versions(Req.Request.t(), String.t(), keyword()) :: result()
  def list_versions(client, skill_id, opts \\ []),
    do: http_get(client, "skills/#{skill_id}/versions", opts)

  @doc "Retrieves a specific version of a skill."
  @spec get_version(Req.Request.t(), String.t(), String.t()) :: result()
  def get_version(client, skill_id, version),
    do: http_get(client, "skills/#{skill_id}/versions/#{version}", [])

  @doc "Deletes a specific version of a skill."
  @spec delete_version(Req.Request.t(), String.t(), String.t()) :: result()
  def delete_version(client, skill_id, version),
    do: http_delete(client, "skills/#{skill_id}/versions/#{version}")

  @doc """
  Creates a skill from a multipart/form-data upload. `form` is a
  `form_multipart`-shaped list, e.g.
  `[file: {bytes, filename: "skill.zip", content_type: "application/zip"}]`.
  """
  @spec create(Req.Request.t(), keyword()) :: result()
  def create(client, form) when is_list(form), do: http_multipart(client, "skills", form)

  @doc "Creates a new version of an existing skill from a multipart upload."
  @spec create_version(Req.Request.t(), String.t(), keyword()) :: result()
  def create_version(client, skill_id, form) when is_list(form),
    do: http_multipart(client, "skills/#{skill_id}/versions", form)

  # --- internals ----------------------------------------------------------

  defp beta(client), do: Client.with_betas(client, [@beta])

  defp http_get(client, url, params),
    do: handle(Req.get(beta(client), url: url, params: params))

  defp http_delete(client, url), do: handle(Req.delete(beta(client), url: url))

  defp http_multipart(client, url, form),
    do: handle(Req.post(beta(client), url: url, form_multipart: form))

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, APIError.from_response(status, body)}

  defp handle({:error, reason}), do: {:error, reason}
end
