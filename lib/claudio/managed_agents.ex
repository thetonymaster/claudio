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

  To walk every page lazily, wrap any list function in `stream/2`:

      Claudio.ManagedAgents.stream(fn opts -> Claudio.ManagedAgents.Agents.list(client, opts) end, limit: 100)
      |> Enum.take(250)
  """

  @type result :: {:ok, map()} | {:error, Claudio.APIError.t() | term()}

  @doc """
  Lazily walks a cursor-paged list, emitting the items of each page's `"data"`.

  `list_fun` receives `opts` (with `page:` set to the previous `"next_page"` after the first
  call) and returns a list function's result. Iteration stops when `"next_page"` is absent or
  `nil`. Pages are fetched only as the stream is consumed.

  A failed page raises: an exception reason (`Claudio.APIError`, `Req.TransportError`, …) is
  raised as is, any other reason as a `RuntimeError`. Items already emitted stay emitted.

      Claudio.ManagedAgents.stream(fn opts -> Sessions.list(client, opts) end, statuses: ["idle"], limit: 100)
      |> Enum.map(& &1["id"])
  """
  @spec stream((keyword() -> result()), keyword()) :: Enumerable.t()
  def stream(list_fun, opts \\ []) when is_function(list_fun, 1) and is_list(opts) do
    Stream.resource(
      fn -> {:fetch, opts} end,
      fn
        :done -> {:halt, :done}
        {:fetch, page_opts} -> fetch_page(list_fun, opts, page_opts)
      end,
      fn _state -> :ok end
    )
  end

  defp fetch_page(list_fun, opts, page_opts) do
    case list_fun.(page_opts) do
      {:ok, %{"data" => items} = body} when is_list(items) ->
        {items, next_state(body, opts)}

      {:ok, other} ->
        raise ArgumentError,
              "Claudio.ManagedAgents.stream/2 expects the list function to return " <>
                "{:ok, %{\"data\" => [...]}}; got: {:ok, #{inspect(other)}}"

      {:error, %{__exception__: true} = exception} ->
        raise exception

      {:error, reason} ->
        raise RuntimeError,
              "Claudio.ManagedAgents.stream/2: fetching a page failed: #{inspect(reason)}"
    end
  end

  # The last page carries no "next_page" key, or `nil` (both observed live). Anything else that
  # isn't a cursor string is an API shape change and crashes (CaseClauseError).
  defp next_state(body, opts) do
    case Map.get(body, "next_page") do
      nil -> :done
      cursor when is_binary(cursor) -> {:fetch, Keyword.put(opts, :page, cursor)}
    end
  end
end
