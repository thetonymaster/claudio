defmodule Claudio.ManagedAgents.Agents do
  @moduledoc """
  Managed Agents **agents** (`/v1/agents`) — versioned agent configurations: `model`, `system`,
  `tools`, `mcp_servers`, `skills`, `multiagent`, `description`, `metadata`.

  Beta `managed-agents-2026-04-01`, attached per request. Returns raw decoded bodies; see
  `Claudio.ManagedAgents`.

  An update that changes something bumps `"version"`; omitted fields are kept, arrays are
  replaced, `metadata` merges per key. Pass the `"version"` you read as an optimistic-concurrency
  check — a stale one returns a 409 `Claudio.APIError` (`:invalid_request_error`). Agents are
  archived, never deleted.

      {:ok, agent} = Agents.create(client, %{name: "researcher", model: "claude-opus-5-5"})
      {:ok, agent} = Agents.update(client, agent["id"], %{version: agent["version"], system: "Be brief."})
      {:ok, first} = Agents.get(client, agent["id"], version: 1)
  """

  import Claudio.ManagedAgents.HTTP, only: [is_id: 1]

  alias Claudio.ManagedAgents
  alias Claudio.ManagedAgents.HTTP

  @doc "Creates an agent. `name` and `model` are required by the API."
  @spec create(Req.Request.t(), map()) :: ManagedAgents.result()
  def create(client, params) when is_map(params), do: HTTP.post(client, "agents", params)

  @doc "Retrieves an agent — the latest version, or `version: n`."
  @spec get(Req.Request.t(), String.t(), keyword()) :: ManagedAgents.result()
  def get(client, id, opts \\ []) when is_id(id) and is_list(opts),
    do: HTTP.get(client, path(id), opts)

  @doc "Updates an agent (`POST /v1/agents/{id}`). Include `version` for a concurrency check."
  @spec update(Req.Request.t(), String.t(), map()) :: ManagedAgents.result()
  def update(client, id, params) when is_id(id) and is_map(params),
    do: HTTP.post(client, path(id), params)

  @doc "Lists agents. Options: `limit`, `page`, `include_archived`, `created_at: [gte: …, lte: …]`."
  @spec list(Req.Request.t(), keyword()) :: ManagedAgents.result()
  def list(client, opts \\ []) when is_list(opts), do: HTTP.get(client, "agents", opts)

  @doc "Archives an agent (sets `archived_at`; there is no delete)."
  @spec archive(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def archive(client, id) when is_id(id), do: HTTP.post(client, path(id) <> "/archive", nil)

  @doc "Lists an agent's versions, newest first. Options: `limit`, `page`."
  @spec list_versions(Req.Request.t(), String.t(), keyword()) :: ManagedAgents.result()
  def list_versions(client, id, opts \\ []) when is_id(id) and is_list(opts),
    do: HTTP.get(client, path(id) <> "/versions", opts)

  defp path(id), do: "agents/#{HTTP.segment(id)}"
end
