defmodule Claudio.ManagedAgents.Environments do
  @moduledoc """
  Managed Agents **environments** (`/v1/environments`) — the sandbox a session runs in:
  `config` is `%{type: "cloud", networking: …, packages: …}` or `%{type: "self_hosted"}`.
  Not versioned.

  Beta `managed-agents-2026-04-01`, attached per request. Returns raw decoded bodies; see
  `Claudio.ManagedAgents`.

  `archive/2` makes an environment read-only (existing sessions continue); `delete/2` works only
  while no session references it — otherwise the API returns an error.

      {:ok, env} =
        Environments.create(client, %{
          name: "default",
          config: %{type: "cloud", networking: %{type: "unrestricted"}}
        })
  """

  import Claudio.ManagedAgents.HTTP, only: [is_id: 1]

  alias Claudio.ManagedAgents
  alias Claudio.ManagedAgents.HTTP

  @doc "Creates an environment. `name` is required by the API."
  @spec create(Req.Request.t(), map()) :: ManagedAgents.result()
  def create(client, params) when is_map(params), do: HTTP.post(client, "environments", params)

  @doc "Retrieves an environment."
  @spec get(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def get(client, id) when is_id(id), do: HTTP.get(client, path(id), [])

  @doc "Updates an environment (`POST /v1/environments/{id}`)."
  @spec update(Req.Request.t(), String.t(), map()) :: ManagedAgents.result()
  def update(client, id, params) when is_id(id) and is_map(params),
    do: HTTP.post(client, path(id), params)

  @doc "Lists environments. Options: `limit`, `page`, `include_archived`."
  @spec list(Req.Request.t(), keyword()) :: ManagedAgents.result()
  def list(client, opts \\ []) when is_list(opts), do: HTTP.get(client, "environments", opts)

  @doc "Archives an environment (read-only; existing sessions continue)."
  @spec archive(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def archive(client, id) when is_id(id), do: HTTP.post(client, path(id) <> "/archive", nil)

  @doc "Deletes an environment. Fails while any session references it."
  @spec delete(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def delete(client, id) when is_id(id), do: HTTP.delete(client, path(id))

  defp path(id), do: "environments/#{HTTP.segment(id)}"
end
