Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ManagedAgentsIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.APIError
  alias Claudio.Files
  alias Claudio.ManagedAgents
  alias Claudio.ManagedAgents.{Agents, Environments, Sessions}

  @moduletag :integration
  @moduletag timeout: 180_000

  @repo "https://github.com/thetonymaster/claudio"

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "agent → environment → idle session → resources, then cleanup", %{client: client} do
    tag = "claudio-it-#{System.unique_integer([:positive])}"

    # Agent: create, version bump, get by version, versions list, stale update -> 409
    {:ok, agent} =
      Agents.create(client, %{
        name: tag,
        model: "claude-sonnet-5-5",
        tools: [%{type: "agent_toolset_20260401"}]
      })

    on_exit(fn -> Agents.archive(client, agent["id"]) end)
    assert %{"type" => "agent", "version" => 1} = agent

    {:ok, v2} = Agents.update(client, agent["id"], %{version: 1, system: "integration v2"})
    assert v2["version"] == 2

    {:ok, v1} = Agents.get(client, agent["id"], version: 1)
    assert v1["version"] == 1
    assert v1["system"] == nil

    assert {:error, %APIError{status_code: 409, type: :invalid_request_error}} =
             Agents.update(client, agent["id"], %{version: 1, system: "stale"})

    versions =
      fn opts -> Agents.list_versions(client, agent["id"], opts) end
      |> ManagedAgents.stream(limit: 1)
      |> Enum.map(& &1["version"])

    assert versions == [2, 1]

    # Environment
    {:ok, env} =
      Environments.create(client, %{
        name: tag,
        config: %{type: "cloud", networking: %{type: "unrestricted"}}
      })

    # Session: idle (no initial_events), with a public repo mounted at creation
    {:ok, session} =
      Sessions.create(client, %{
        agent: agent["id"],
        environment_id: env["id"],
        resources: [%{type: "github_repository", url: @repo}]
      })

    # Registered after the environment so on_exit (LIFO) deletes the session first.
    on_exit(fn -> Environments.delete(client, env["id"]) end)
    on_exit(fn -> Sessions.delete(client, session["id"]) end)

    assert session["status"] == "idle"
    [%{"type" => "github_repository", "id" => repo_rid}] = session["resources"]

    {:ok, updated} =
      Sessions.update(client, session["id"], %{title: tag, metadata: %{suite: "it"}})

    assert updated["title"] == tag
    assert updated["metadata"] == %{"suite" => "it"}

    # No model ran; the only event is the persisted `session.updated` from the update above.
    assert {:ok, %{"data" => [%{"type" => "session.updated", "title" => ^tag}]}} =
             Sessions.list_events(client, session["id"])

    {:ok, listed} = Sessions.list(client, statuses: ["idle"], agent_id: agent["id"])
    assert Enum.any?(listed["data"], &(&1["id"] == session["id"]))

    # File resource: upload, mount, inspect, remove
    {:ok, file} =
      Files.upload(client, "claudio integration\n",
        filename: "#{tag}.txt",
        content_type: "text/plain"
      )

    on_exit(fn -> Files.delete(client, file["id"]) end)

    {:ok, res} =
      Sessions.add_resource(client, session["id"], %{type: "file", file_id: file["id"]})

    assert "sesrsc_" <> _ = res["id"]
    # The API mounts a session-scoped copy: a new file id, mount path keeps the original (F11).
    refute res["file_id"] == file["id"]
    assert res["mount_path"] == "/mnt/session/uploads/#{file["id"]}"

    {:ok, %{"data" => resources}} = Sessions.list_resources(client, session["id"])
    assert Enum.sort(Enum.map(resources, & &1["type"])) == ["file", "github_repository"]

    assert {:ok, %{"id" => _}} = Sessions.get_resource(client, session["id"], res["id"])

    assert {:ok, %{"type" => "github_repository"}} =
             Sessions.update_resource(client, session["id"], repo_rid, %{
               authorization_token: "ghp_dummy_token"
             })

    assert {:ok, %{"type" => "session_resource_deleted"}} =
             Sessions.delete_resource(client, session["id"], res["id"])

    assert {:error, %APIError{status_code: 404}} =
             Sessions.get_resource(client, session["id"], res["id"])

    # Archive is a bodyless POST (Review Focus 4): assert it live, not only in on_exit.
    assert {:ok, %{"archived_at" => archived_at}} = Agents.archive(client, agent["id"])
    assert is_binary(archived_at)
  end
end
