defmodule Claudio.ManagedAgents.Sessions do
  @moduledoc """
  Managed Agents **sessions** (`/v1/sessions`) — one run of an agent in an environment, plus
  its events and mounted resources.

  Beta `managed-agents-2026-04-01`, attached per request. Returns raw decoded bodies; see
  `Claudio.ManagedAgents`.

  A session created without `initial_events` starts `idle`; sending a `user.message` starts
  it. Typed events and the run loop (stream, custom tools, confirmations) come in a later
  release; for now events are plain maps:

      {:ok, session} = Sessions.create(client, %{agent: agent_id, environment_id: env_id})

      {:ok, _} =
        Sessions.send_events(client, session["id"], [
          %{type: "user.message", content: [%{type: "text", text: "Summarise the repo."}]}
        ])

      {:ok, %{"data" => events}} = Sessions.list_events(client, session["id"], order: :asc)

  ## Resources

  `create/2` takes `resources:` (`file`, `github_repository`, `memory_store`). Mid-session,
  `add_resource/3` accepts only `file` resources, and a file resource needs the agent's
  `agent_toolset_20260401` with `read` enabled. `update_resource/4` rotates a
  `github_repository`'s `authorization_token` — the only update the API accepts.

  Neither `archive/2` nor `delete/2` works on a `running` session; interrupt it and wait for
  `idle` first. `delete/2` removes events, sandbox and produced files.
  """

  import Claudio.ManagedAgents.HTTP, only: [is_id: 1]

  alias Claudio.ManagedAgents
  alias Claudio.ManagedAgents.HTTP

  @doc """
  Creates a session. `agent` (an id, or `%{type: "agent", id: …, version: …}`) and
  `environment_id` are required by the API.
  """
  @spec create(Req.Request.t(), map()) :: ManagedAgents.result()
  def create(client, params) when is_map(params), do: HTTP.post(client, "sessions", params)

  @doc "Retrieves a session (status, resolved agent snapshot, usage, stats)."
  @spec get(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def get(client, id) when is_id(id), do: HTTP.get(client, path(id), [])

  @doc """
  Updates a session: `title`, `metadata`, `budget`, and (while idle) `agent.tools` /
  `agent.mcp_servers`.
  """
  @spec update(Req.Request.t(), String.t(), map()) :: ManagedAgents.result()
  def update(client, id, params) when is_id(id) and is_map(params),
    do: HTTP.post(client, path(id), params)

  @doc """
  Lists sessions. Options include `statuses: [...]`, `created_at: [gte: …]`, `agent_id`,
  `agent_version`, `deployment_id`, `memory_store_id`, `include_archived`, `order`, `limit`,
  `page`.
  """
  @spec list(Req.Request.t(), keyword()) :: ManagedAgents.result()
  def list(client, opts \\ []) when is_list(opts), do: HTTP.get(client, "sessions", opts)

  @doc "Archives a session (keeps history, blocks new events). Not allowed while `running`."
  @spec archive(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def archive(client, id) when is_id(id), do: HTTP.post(client, path(id) <> "/archive", nil)

  @doc "Deletes a session permanently. Not allowed while `running`."
  @spec delete(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def delete(client, id) when is_id(id), do: HTTP.delete(client, path(id))

  @doc """
  Sends events (a list of event maps) to a session: `POST …/events` with
  `%{"events" => events}`.
  """
  @spec send_events(Req.Request.t(), String.t(), [map()]) :: ManagedAgents.result()
  def send_events(client, id, events) when is_id(id) and is_list(events),
    do: HTTP.post(client, path(id) <> "/events", %{"events" => events})

  def send_events(_client, _id, events) when not is_list(events) do
    raise ArgumentError,
          "Claudio.ManagedAgents.Sessions.send_events/3 expects a list of event maps; " <>
            "got: #{inspect(events)}"
  end

  @doc """
  Lists a session's events. Options: `types: [...]`, `created_at: [...]`, `order`, `limit`,
  `page`.
  """
  @spec list_events(Req.Request.t(), String.t(), keyword()) :: ManagedAgents.result()
  def list_events(client, id, opts \\ []) when is_id(id) and is_list(opts),
    do: HTTP.get(client, path(id) <> "/events", opts)

  @doc "Mounts a resource mid-session. Only `file` resources are accepted after creation."
  @spec add_resource(Req.Request.t(), String.t(), map()) :: ManagedAgents.result()
  def add_resource(client, id, resource) when is_id(id) and is_map(resource),
    do: HTTP.post(client, path(id) <> "/resources", resource)

  @doc "Lists a session's resources."
  @spec list_resources(Req.Request.t(), String.t(), keyword()) :: ManagedAgents.result()
  def list_resources(client, id, opts \\ []) when is_id(id) and is_list(opts),
    do: HTTP.get(client, path(id) <> "/resources", opts)

  @doc "Retrieves one session resource."
  @spec get_resource(Req.Request.t(), String.t(), String.t()) :: ManagedAgents.result()
  def get_resource(client, id, rid) when is_id(id) and is_id(rid),
    do: HTTP.get(client, resource_path(id, rid), [])

  @doc "Updates a resource — in practice, rotates a `github_repository`'s `authorization_token`."
  @spec update_resource(Req.Request.t(), String.t(), String.t(), map()) ::
          ManagedAgents.result()
  def update_resource(client, id, rid, params) when is_id(id) and is_id(rid) and is_map(params),
    do: HTTP.post(client, resource_path(id, rid), params)

  @doc "Removes a resource from a session."
  @spec delete_resource(Req.Request.t(), String.t(), String.t()) :: ManagedAgents.result()
  def delete_resource(client, id, rid) when is_id(id) and is_id(rid),
    do: HTTP.delete(client, resource_path(id, rid))

  defp path(id), do: "sessions/#{HTTP.segment(id)}"
  defp resource_path(id, rid), do: path(id) <> "/resources/#{HTTP.segment(rid)}"
end
