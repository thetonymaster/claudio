defmodule Claudio.ManagedAgents do
  @moduledoc """
  Anthropic **Managed Agents** — server-hosted agents that run in a managed sandbox.

  **Beta.** Every call sends `anthropic-beta: managed-agents-2026-04-01`, merged with whatever
  betas the client already carries — use your ordinary client:

      client = Claudio.Client.new(%{token: "sk-ant-...", version: "2023-06-01"})

      {:ok, agent} =
        Claudio.ManagedAgents.Agents.create(client, %{
          name: "researcher",
          model: "claude-opus-5-5",
          tools: [%{type: "agent_toolset_20260401"}]
        })

      {:ok, env} =
        Claudio.ManagedAgents.Environments.create(client, %{
          name: "default",
          config: %{type: "cloud", networking: %{type: "unrestricted"}}
        })

      {:ok, session} =
        Claudio.ManagedAgents.Sessions.create(client, %{agent: agent["id"], environment_id: env["id"]})

  Modules: `Claudio.ManagedAgents.Agents`, `Claudio.ManagedAgents.Environments`,
  `Claudio.ManagedAgents.Sessions`.

  ## Return values

  Every function returns the raw decoded body (`{:ok, map()}`, string keys) or
  `{:error, %Claudio.APIError{}}` for a non-2xx response — the same contract as
  `Claudio.Skills` and `Claudio.Admin`. Bodies are passed through; the API validates them.

  ## List options

  List functions take Elixir-shaped options and encode the API's bracketed query names:

      Claudio.ManagedAgents.Sessions.list(client,
        statuses: ["idle", "running"],                 # statuses[]=idle&statuses[]=running
        created_at: [gte: ~U[2026-09-01 00:00:00Z]],   # created_at[gte]=2026-09-01T00:00:00Z
        limit: 50
      )

  A list value repeats `key[]`, a keyword value becomes `key[sub]`, a `DateTime` is sent as
  ISO 8601. `nil`, `[]`, maps and nested lists raise `ArgumentError`.

  Lists are cursor-paged: pass the previous response's `"next_page"` as `page:`. The last page
  has no `"next_page"` (absent or `nil`).
  """

  @type result :: {:ok, map()} | {:error, Claudio.APIError.t() | term()}
end
