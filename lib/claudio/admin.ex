defmodule Claudio.Admin do
  @moduledoc """
  Anthropic Admin API client — programmatic management of an organization's
  members, invites, workspaces, API keys, and usage/cost reports.

  ## Authentication

  The Admin API requires an **Admin API key** (`sk-ant-admin…`), provisioned by
  an organization admin in the Console. It travels in the same `x-api-key`
  header as a regular key, so build the client the usual way — just pass the
  admin key:

      client = Claudio.Client.new(%{token: "sk-ant-admin-...", version: "2023-06-01"})
      {:ok, org} = Claudio.Admin.get_organization(client)

  GA — no beta header. All functions return the raw decoded body
  (`{:ok, map()}`); a non-2xx response maps to `{:error, %Claudio.APIError{}}`
  and a transport error to `{:error, term()}`, consistent with
  `Claudio.Models` / `Claudio.Files`.

  ## Not covered

  - Workspace-member, service-account, and federation endpoints require an
    `org:admin` **OAuth** token (not an admin key) — see S8.
  - Creating/deleting API keys is Console-only by design.
  """

  alias Claudio.APIError

  @type result :: {:ok, map()} | {:error, APIError.t() | term()}

  # --- Organization -------------------------------------------------------

  @doc "Returns the organization the admin key belongs to (`GET /v1/organizations/me`)."
  @spec get_organization(Req.Request.t()) :: result()
  def get_organization(client), do: get(client, "organizations/me")

  # --- Organization members ----------------------------------------------

  @doc "Lists organization members. Opts (`:limit`/`:before_id`/`:after_id`) become query params."
  @spec list_users(Req.Request.t(), keyword()) :: result()
  def list_users(client, opts \\ []), do: get(client, "organizations/users", opts)

  @doc "Retrieves a single organization member by id."
  @spec get_user(Req.Request.t(), String.t()) :: result()
  def get_user(client, user_id), do: get(client, "organizations/users/#{user_id}")

  @doc "Updates a member's role, e.g. `%{\"role\" => \"developer\"}`."
  @spec update_user(Req.Request.t(), String.t(), map()) :: result()
  def update_user(client, user_id, body),
    do: post(client, "organizations/users/#{user_id}", body)

  @doc "Removes a member from the organization. (Admins cannot be removed via the API.)"
  @spec remove_user(Req.Request.t(), String.t()) :: result()
  def remove_user(client, user_id), do: delete(client, "organizations/users/#{user_id}")

  # --- Invites ------------------------------------------------------------

  @doc "Lists organization invites."
  @spec list_invites(Req.Request.t(), keyword()) :: result()
  def list_invites(client, opts \\ []), do: get(client, "organizations/invites", opts)

  @doc "Retrieves a single invite by id."
  @spec get_invite(Req.Request.t(), String.t()) :: result()
  def get_invite(client, invite_id), do: get(client, "organizations/invites/#{invite_id}")

  @doc "Creates an invite, e.g. `%{\"email\" => \"x@y.com\", \"role\" => \"developer\"}`."
  @spec create_invite(Req.Request.t(), map()) :: result()
  def create_invite(client, body), do: post(client, "organizations/invites", body)

  @doc "Deletes a pending invite by id."
  @spec delete_invite(Req.Request.t(), String.t()) :: result()
  def delete_invite(client, invite_id), do: delete(client, "organizations/invites/#{invite_id}")

  # --- Workspaces ---------------------------------------------------------

  @doc "Lists workspaces."
  @spec list_workspaces(Req.Request.t(), keyword()) :: result()
  def list_workspaces(client, opts \\ []), do: get(client, "organizations/workspaces", opts)

  @doc "Retrieves a single workspace by id."
  @spec get_workspace(Req.Request.t(), String.t()) :: result()
  def get_workspace(client, id), do: get(client, "organizations/workspaces/#{id}")

  @doc "Creates a workspace, e.g. `%{\"name\" => \"Production\"}`."
  @spec create_workspace(Req.Request.t(), map()) :: result()
  def create_workspace(client, body), do: post(client, "organizations/workspaces", body)

  @doc "Updates a workspace (e.g. rename)."
  @spec update_workspace(Req.Request.t(), String.t(), map()) :: result()
  def update_workspace(client, id, body),
    do: post(client, "organizations/workspaces/#{id}", body)

  @doc "Archives a workspace."
  @spec archive_workspace(Req.Request.t(), String.t()) :: result()
  def archive_workspace(client, id),
    do: post(client, "organizations/workspaces/#{id}/archive", %{})

  # --- API keys -----------------------------------------------------------

  @doc "Lists API keys. Opts (`:limit`/`:status`/`:workspace_id`) become query params."
  @spec list_api_keys(Req.Request.t(), keyword()) :: result()
  def list_api_keys(client, opts \\ []), do: get(client, "organizations/api_keys", opts)

  @doc "Retrieves a single API key by id."
  @spec get_api_key(Req.Request.t(), String.t()) :: result()
  def get_api_key(client, id), do: get(client, "organizations/api_keys/#{id}")

  @doc "Updates an API key, e.g. `%{\"status\" => \"inactive\"}` or `%{\"name\" => \"…\"}`."
  @spec update_api_key(Req.Request.t(), String.t(), map()) :: result()
  def update_api_key(client, id, body), do: post(client, "organizations/api_keys/#{id}", body)

  # --- Usage & cost reports ----------------------------------------------

  @doc """
  Organization message usage report. Opts (e.g. `:starting_at`, `:ending_at`,
  `:group_by`, `:bucket_width`) pass through as query params.
  """
  @spec usage_report(Req.Request.t(), keyword()) :: result()
  def usage_report(client, opts \\ []),
    do: get(client, "organizations/usage_report/messages", opts)

  @doc "Organization cost report. Opts pass through as query params."
  @spec cost_report(Req.Request.t(), keyword()) :: result()
  def cost_report(client, opts \\ []), do: get(client, "organizations/cost_report", opts)

  # --- internals ----------------------------------------------------------

  defp get(client, url, params \\ []), do: handle(Req.get(client, url: url, params: params))
  defp post(client, url, body), do: handle(Req.post(client, url: url, json: body))
  defp delete(client, url), do: handle(Req.delete(client, url: url))

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, APIError.from_response(status, body)}

  defp handle({:error, reason}), do: {:error, reason}
end
