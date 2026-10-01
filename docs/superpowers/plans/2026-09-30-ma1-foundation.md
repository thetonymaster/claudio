# MA1 — Managed Agents Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raw-map clients for Managed Agents Agents, Environments and Sessions (incl. session events and resources), plus bracketed query encoding and a lazy pagination stream.

**Architecture:** A private transport module (`Claudio.ManagedAgents.HTTP`) attaches the `managed-agents-2026-04-01` beta per request via `Claudio.Client.with_betas/2`, encodes Elixir-shaped options into the API's bracketed query params, escapes id path segments, and maps non-2xx to `Claudio.APIError`. Three thin resource modules call it. `Claudio.ManagedAgents` holds the overview doc, the shared `result` type and `stream/2`.

**Tech Stack:** Elixir ≥ 1.15, Req (`~> 0.6 and >= 0.6.1`), Jason, Bypass (tests), ExUnit.

**Spec:** `docs/superpowers/specs/2026-09-30-ma1-foundation-design.md` (facts F1–F12; read it first). Roadmap: `docs/superpowers/specs/2026-09-30-managed-agents-roadmap.md`.

## Global Constraints

- Beta header value, verbatim: `managed-agents-2026-04-01` — merged with the client's betas (union, dedupe), never replacing them (F1, F12).
- Every resource function returns `{:ok, map()} | {:error, Claudio.APIError.t() | term()}` — the raw decoded, string-keyed body (`Skills`/`Admin` contract).
- No local validation of body fields or option names; the API's 400 is authoritative.
- No silent fallbacks: unencodable query values, `nil`, and empty lists raise `ArgumentError` naming the option and `inspect/1`-ing the value.
- Ids: non-empty binaries, guarded (`FunctionClauseError` otherwise), percent-escaped as one path segment.
- Pagination: `page` in, `next_page` out; the last page has `next_page` **absent or `nil`** (F8).
- `Claudio.Agent` is not touched (deprecation is MA2). `@version` in `mix.exs` is not bumped (0.8.0 ships after MA4).
- Commits: add files individually (never `git add .`); no AI attribution / Co-Authored-By lines.
- Every task ends green on: `mix format --check-formatted && mix compile --warnings-as-errors && mix test` (integration excluded by default).

## Review Focus

1. **`DateTime` filter values** (`created_at: [gte: ~U[2026-09-01 00:00:00Z]]`) — a user expects ISO 8601 (`2026-09-01T00:00:00Z`); `to_string/1` would emit a space-separated form the API may reject. Pinned in Task 1 (encoder test).
2. **Empty list filter** (`statuses: []`) — ambiguous ("none" vs "any"); must raise, not silently drop the filter. Pinned in Task 1.
3. **Unsafe ids** — `""` must not turn `get/2` into `GET agents/` (a list call), and `"a/b"` must not reach another endpoint. Pinned in Task 1 (`segment/1`) and Task 2 (guard + escaped path).
4. **Bodyless archive POST** — archive endpoints must send no body (not `{}` / `null`); the live API accepted a bodyless POST (P1–P9). Pinned in Task 1 (Bypass reads an empty body) and Task 6 (live).
5. **`stream/2` resumed from a cursor** — `page:` in the initial opts must be used for the first fetch, and `limit:` must be kept on every page. Pinned in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/claudio/managed_agents.ex` (create) | Overview moduledoc, `@type result`, `stream/2` |
| `lib/claudio/managed_agents/http.ex` (create) | `@moduledoc false`: `get/3`, `post/3`, `delete/2`, `encode_query/1`, `segment/1`, `is_id/1` guard |
| `lib/claudio/managed_agents/agents.ex` (create) | `/v1/agents` |
| `lib/claudio/managed_agents/environments.ex` (create) | `/v1/environments` |
| `lib/claudio/managed_agents/sessions.ex` (create) | `/v1/sessions` + events + resources |
| `test/managed_agents/support.exs` (create) | Shared Bypass helpers, loaded with `Code.require_file` (not a `_test.exs`, so not run on its own — same pattern as `test/integration/integration_helper.exs`) |
| `test/managed_agents/{http,agents,environments,sessions,managed_agents}_test.exs` (create) | Unit tests |
| `test/integration/managed_agents_integration_test.exs` (create) | Live flow, `:integration` |
| `CHANGELOG.md`, `CLAUDE.md`, `README.md`, `mix.exs` (modify) | Docs + ExDoc group |

---

### Task 1: Transport, query encoding, shared type, test support

**Files:**
- Create: `lib/claudio/managed_agents.ex`
- Create: `lib/claudio/managed_agents/http.ex`
- Create: `test/managed_agents/support.exs`
- Test: `test/managed_agents/http_test.exs`

**Interfaces:**
- Produces:
  - `@type Claudio.ManagedAgents.result :: {:ok, map()} | {:error, Claudio.APIError.t() | term()}`
  - `Claudio.ManagedAgents.HTTP.get(Req.Request.t(), String.t(), keyword()) :: result`
  - `Claudio.ManagedAgents.HTTP.post(Req.Request.t(), String.t(), map() | nil) :: result` (`nil` → no body)
  - `Claudio.ManagedAgents.HTTP.delete(Req.Request.t(), String.t()) :: result`
  - `Claudio.ManagedAgents.HTTP.encode_query(keyword()) :: [{String.t(), String.t()}]`
  - `Claudio.ManagedAgents.HTTP.segment(String.t()) :: String.t()`
  - `defguard Claudio.ManagedAgents.HTTP.is_id(id)` — `is_binary(id) and id != ""`
  - `@beta "managed-agents-2026-04-01"`; `HTTP.beta/0` returns it (tests use it)
  - Test support module `Claudio.ManagedAgentsTestSupport`: `setup_client/1`, `json/3`, `betas/1`, `expect_call/5`

- [ ] **Step 1: Write the test support file**

`test/managed_agents/support.exs`:

```elixir
defmodule Claudio.ManagedAgentsTestSupport do
  @moduledoc false
  import ExUnit.Assertions

  @beta "managed-agents-2026-04-01"

  # ExUnit setup callback: a Bypass server and a client pointed at it.
  def setup_client(_context) do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01"},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # The anthropic-beta header split into its flags ([] when absent).
  def betas(conn) do
    conn
    |> Plug.Conn.get_req_header("anthropic-beta")
    |> Enum.flat_map(&String.split(&1, ","))
  end

  # Expects exactly one `method path` request carrying the managed-agents beta. `check` gets
  # the conn, the decoded query (a list of {name, value} pairs, order kept) and the raw body.
  def expect_call(bypass, method, path, response \\ %{"ok" => true}, check \\ fn _, _, _ -> :ok end) do
    Bypass.expect_once(bypass, method, path, fn conn ->
      assert @beta in betas(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      query = URI.query_decoder(conn.query_string) |> Enum.to_list()
      check.(conn, query, raw)
      json(conn, 200, response)
    end)
  end
end
```

- [ ] **Step 2: Write the failing tests**

`test/managed_agents/http_test.exs`:

```elixir
Code.require_file("support.exs", __DIR__)

defmodule Claudio.ManagedAgents.HTTPTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.APIError
  alias Claudio.ManagedAgents.HTTP

  describe "encode_query/1" do
    test "scalars become strings" do
      assert HTTP.encode_query(limit: 20, include_archived: true, order: :desc, agent_id: "agent_1") ==
               [
                 {"limit", "20"},
                 {"include_archived", "true"},
                 {"order", "desc"},
                 {"agent_id", "agent_1"}
               ]
    end

    test "a list repeats key[] in order" do
      assert HTTP.encode_query(statuses: ["idle", "running"]) ==
               [{"statuses[]", "idle"}, {"statuses[]", "running"}]
    end

    test "a keyword list becomes key[sub]" do
      assert HTTP.encode_query(created_at: [gte: "2026-09-01T00:00:00Z", lt: "2026-10-01T00:00:00Z"]) ==
               [
                 {"created_at[gte]", "2026-09-01T00:00:00Z"},
                 {"created_at[lt]", "2026-10-01T00:00:00Z"}
               ]
    end

    test "DateTime values are ISO 8601, at top level, in lists and in keywords" do
      dt = ~U[2026-09-01 00:00:00Z]

      assert HTTP.encode_query(created_at: [gte: dt]) == [{"created_at[gte]", "2026-09-01T00:00:00Z"}]
      assert HTTP.encode_query(since: dt) == [{"since", "2026-09-01T00:00:00Z"}]
    end

    test "mixed options keep their order" do
      assert HTTP.encode_query(statuses: ["idle"], created_at: [gte: "x"], limit: 1) ==
               [{"statuses[]", "idle"}, {"created_at[gte]", "x"}, {"limit", "1"}]
    end

    test "empty opts encode to []" do
      assert HTTP.encode_query([]) == []
    end

    test "nil raises, naming the option" do
      assert_raise ArgumentError, ~r/:page.*nil/, fn -> HTTP.encode_query(page: nil) end
    end

    test "an empty list raises (ambiguous filter)" do
      assert_raise ArgumentError, ~r/:statuses.*\[\]/, fn -> HTTP.encode_query(statuses: []) end
    end

    test "a map raises" do
      assert_raise ArgumentError, ~r/:filter/, fn -> HTTP.encode_query(filter: %{a: 1}) end
    end

    test "a nested list raises" do
      assert_raise ArgumentError, ~r/:statuses/, fn -> HTTP.encode_query(statuses: [["idle"]]) end
    end

    test "a list inside a keyword raises" do
      assert_raise ArgumentError, ~r/:created_at/, fn -> HTTP.encode_query(created_at: [gte: ["x"]]) end
    end

    test "nil inside a list or keyword raises" do
      assert_raise ArgumentError, ~r/:statuses/, fn -> HTTP.encode_query(statuses: ["idle", nil]) end
      assert_raise ArgumentError, ~r/:created_at/, fn -> HTTP.encode_query(created_at: [gte: nil]) end
    end
  end

  describe "segment/1 and is_id/1" do
    test "segment escapes everything outside the unreserved set" do
      assert HTTP.segment("agent_01Ab-c.d~e") == "agent_01Ab-c.d~e"
      assert HTTP.segment("a/b") == "a%2Fb"
      assert HTTP.segment("../x?y#z") == "..%2Fx%3Fy%23z"
    end

    test "is_id accepts non-empty binaries only" do
      import HTTP, only: [is_id: 1]
      check = fn x -> if is_id(x), do: true, else: false end
      assert check.("agent_1")
      refute check.("")
      refute check.(nil)
      refute check.(:agent_1)
    end
  end

  describe "transport" do
    setup :setup_client

    test "get sends the beta and the encoded query", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions", %{"data" => []}, fn _conn, query, _raw ->
        assert query == [{"statuses[]", "idle"}, {"limit", "5"}]
      end)

      assert {:ok, %{"data" => []}} = HTTP.get(client, "sessions", statuses: ["idle"], limit: 5)
    end

    test "the beta is merged with the client's betas and deduped", %{bypass: bypass} do
      client =
        Claudio.Client.new(
          %{token: "t", version: "2023-06-01", beta: ["foo-2026-01-01", HTTP.beta()]},
          "http://localhost:#{bypass.port}/"
        )

      Bypass.expect_once(bypass, "GET", "/agents", fn conn ->
        assert Enum.sort(betas(conn)) == Enum.sort(["foo-2026-01-01", HTTP.beta()])
        json(conn, 200, %{"data" => []})
      end)

      assert {:ok, _} = HTTP.get(client, "agents", [])
    end

    test "post with a map sends JSON", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/agents", %{"id" => "agent_1"}, fn conn, _query, raw ->
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")
        assert Jason.decode!(raw) == %{"name" => "n", "model" => "m"}
      end)

      assert {:ok, %{"id" => "agent_1"}} = HTTP.post(client, "agents", %{name: "n", model: "m"})
    end

    test "post with nil sends no body", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/agents/agent_1/archive", %{"id" => "agent_1"}, fn _conn, _query, raw ->
        assert raw == ""
      end)

      assert {:ok, _} = HTTP.post(client, "agents/agent_1/archive", nil)
    end

    test "delete issues a DELETE", %{client: client, bypass: bypass} do
      expect_call(bypass, "DELETE", "/environments/env_1", %{"type" => "environment_deleted"})
      assert {:ok, %{"type" => "environment_deleted"}} = HTTP.delete(client, "environments/env_1")
    end

    test "a JSON error becomes an APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/agents/agent_1", fn conn ->
        json(conn, 409, %{
          "type" => "error",
          "error" => %{
            "type" => "invalid_request_error",
            "message" => "Concurrent modification detected. Please fetch the latest version and retry."
          }
        })
      end)

      assert {:error, %APIError{status_code: 409, type: :invalid_request_error, message: "Concurrent" <> _}} =
               HTTP.post(client, "agents/agent_1", %{version: 1})
    end

    test "a non-JSON 5xx becomes an APIError", %{client: client, bypass: bypass} do
      client = Req.merge(client, retry: false)

      Bypass.expect_once(bypass, "GET", "/agents", fn conn ->
        Plug.Conn.resp(conn, 502, "<html>bad gateway</html>")
      end)

      assert {:error, %APIError{status_code: 502, type: :api_error}} = HTTP.get(client, "agents", [])
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test test/managed_agents/http_test.exs`
Expected: compile error — `module Claudio.ManagedAgents.HTTP is not loaded`.

- [ ] **Step 4: Write `lib/claudio/managed_agents.ex` (type + overview; `stream/2` arrives in Task 5)**

```elixir
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
```

- [ ] **Step 5: Write `lib/claudio/managed_agents/http.ex`**

```elixir
defmodule Claudio.ManagedAgents.HTTP do
  @moduledoc false
  # Transport shared by the Managed Agents modules: per-request beta, bracketed query
  # encoding, id path segments, APIError mapping.

  alias Claudio.APIError
  alias Claudio.Client
  alias Claudio.ManagedAgents

  @beta "managed-agents-2026-04-01"

  @doc false
  def beta, do: @beta

  @doc false
  defguard is_id(id) when is_binary(id) and id != ""

  @spec get(Req.Request.t(), String.t(), keyword()) :: ManagedAgents.result()
  def get(client, path, opts) when is_list(opts),
    do: client |> with_beta() |> Req.get(url: path, params: encode_query(opts)) |> handle()

  @spec post(Req.Request.t(), String.t(), map() | nil) :: ManagedAgents.result()
  def post(client, path, nil), do: client |> with_beta() |> Req.post(url: path) |> handle()

  def post(client, path, body) when is_map(body),
    do: client |> with_beta() |> Req.post(url: path, json: body) |> handle()

  @spec delete(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def delete(client, path), do: client |> with_beta() |> Req.delete(url: path) |> handle()

  @doc false
  # One path segment: everything outside RFC 3986's unreserved set is percent-escaped, so an
  # id can never reach another endpoint ("a/b" -> "a%2Fb").
  @spec segment(String.t()) :: String.t()
  def segment(id) when is_id(id), do: URI.encode(id, &URI.char_unreserved?/1)

  @doc false
  # [statuses: ["idle"], created_at: [gte: dt], limit: 5]
  #   -> [{"statuses[]", "idle"}, {"created_at[gte]", "2026-...Z"}, {"limit", "5"}]
  @spec encode_query(keyword()) :: [{String.t(), String.t()}]
  def encode_query(opts) when is_list(opts), do: Enum.flat_map(opts, &encode_option/1)

  defp encode_option({key, [_ | _] = value}) do
    if Keyword.keyword?(value) do
      Enum.map(value, fn {sub, v} -> {"#{key}[#{sub}]", scalar!(key, v)} end)
    else
      Enum.map(value, fn v -> {"#{key}[]", scalar!(key, v)} end)
    end
  end

  defp encode_option({key, value}), do: [{to_string(key), scalar!(key, value)}]

  defp scalar!(_key, %DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp scalar!(_key, v) when is_binary(v), do: v
  defp scalar!(_key, v) when is_integer(v), do: Integer.to_string(v)
  defp scalar!(_key, v) when is_boolean(v), do: Atom.to_string(v)
  defp scalar!(_key, v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)

  defp scalar!(key, v) do
    raise ArgumentError,
          "Claudio.ManagedAgents query option #{inspect(key)} must be a string, integer, " <>
            "boolean, atom or DateTime (or a non-empty list / keyword list of those); " <>
            "got: #{inspect(v)}"
  end

  defp with_beta(client), do: Client.with_betas(client, [@beta])

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, APIError.from_response(status, body)}

  defp handle({:error, reason}), do: {:error, reason}
end
```

Note on `encode_option/1`: `[_ | _]` only matches non-empty lists, so `[]` falls through to the
scalar clause and raises there (with `got: []`), as does `nil`. A list like `["idle", nil]`
raises from `scalar!/2` on the `nil` element. `Keyword.keyword?/1` is true only when every
element is `{atom, _}`, so a list of strings takes the `key[]` branch and `[["idle"]]` raises
on the inner list.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/managed_agents/http_test.exs`
Expected: all pass. If the "post with nil sends no body" test fails because Req sends `content-length: 0` with some body, that's fine as long as `raw == ""`; if it sends `null`/`{}`, stop and report.

- [ ] **Step 7: Quality gates**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: no warnings, Credo clean, whole suite green.

- [ ] **Step 8: Commit**

```bash
git add lib/claudio/managed_agents.ex lib/claudio/managed_agents/http.ex test/managed_agents/support.exs test/managed_agents/http_test.exs
git commit -m "feat(managed-agents): transport with per-request beta and bracketed query encoding"
```

---

### Task 2: Agents

**Files:**
- Create: `lib/claudio/managed_agents/agents.ex`
- Test: `test/managed_agents/agents_test.exs`

**Interfaces:**
- Consumes: `HTTP.get/3`, `HTTP.post/3`, `HTTP.segment/1`, `HTTP.is_id/1`, `Claudio.ManagedAgents.result/0`, test support from Task 1.
- Produces (all return `Claudio.ManagedAgents.result()`):
  - `Agents.create(client, params :: map())`
  - `Agents.get(client, id :: String.t(), opts :: keyword() \\ [])` — `version: n`
  - `Agents.update(client, id, params :: map())`
  - `Agents.list(client, opts \\ [])`
  - `Agents.archive(client, id)`
  - `Agents.list_versions(client, id, opts \\ [])`

- [ ] **Step 1: Write the failing tests**

`test/managed_agents/agents_test.exs`:

```elixir
Code.require_file("support.exs", __DIR__)

defmodule Claudio.ManagedAgents.AgentsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.ManagedAgents.Agents

  setup :setup_client

  test "create posts the params", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/agents", %{"id" => "agent_1", "version" => 1}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"name" => "researcher", "model" => "claude-opus-5-5"}
    end)

    assert {:ok, %{"id" => "agent_1", "version" => 1}} =
             Agents.create(client, %{name: "researcher", model: "claude-opus-5-5"})
  end

  test "get without opts sends no query", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents/agent_1", %{"id" => "agent_1"}, fn _c, query, _r ->
      assert query == []
    end)

    assert {:ok, %{"id" => "agent_1"}} = Agents.get(client, "agent_1")
  end

  test "get with version: sends ?version=", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents/agent_1", %{"version" => 1}, fn _c, query, _r ->
      assert query == [{"version", "1"}]
    end)

    assert {:ok, %{"version" => 1}} = Agents.get(client, "agent_1", version: 1)
  end

  test "update posts to the agent path, version passed through", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/agents/agent_1", %{"version" => 2}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"version" => 1, "system" => "v2"}
    end)

    assert {:ok, %{"version" => 2}} = Agents.update(client, "agent_1", %{version: 1, system: "v2"})
  end

  test "list encodes options", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents", %{"data" => []}, fn _c, query, _r ->
      assert query == [{"include_archived", "true"}, {"limit", "10"}]
    end)

    assert {:ok, %{"data" => []}} = Agents.list(client, include_archived: true, limit: 10)
  end

  test "archive posts no body", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/agents/agent_1/archive", %{"archived_at" => "t"}, fn _c, _q, raw ->
      assert raw == ""
    end)

    assert {:ok, %{"archived_at" => "t"}} = Agents.archive(client, "agent_1")
  end

  test "list_versions hits the versions path", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents/agent_1/versions", %{"data" => []}, fn _c, query, _r ->
      assert query == [{"limit", "1"}]
    end)

    assert {:ok, %{"data" => []}} = Agents.list_versions(client, "agent_1", limit: 1)
  end

  test "ids are escaped as one path segment", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      assert conn.request_path == "/agents/a%2Fb"
      json(conn, 404, %{"type" => "error", "error" => %{"type" => "not_found_error", "message" => "x"}})
    end)

    assert {:error, %Claudio.APIError{status_code: 404}} = Agents.get(client, "a/b")
  end

  test "an empty or non-binary id raises FunctionClauseError", %{client: client} do
    assert_raise FunctionClauseError, fn -> Agents.get(client, "") end
    assert_raise FunctionClauseError, fn -> Agents.archive(client, nil) end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/managed_agents/agents_test.exs`
Expected: compile error — `Claudio.ManagedAgents.Agents` undefined.

- [ ] **Step 3: Implement `lib/claudio/managed_agents/agents.ex`**

```elixir
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
    do: HTTP.get(client, "agents/#{HTTP.segment(id)}", opts)

  @doc "Updates an agent (`POST /v1/agents/{id}`). Include `version` for a concurrency check."
  @spec update(Req.Request.t(), String.t(), map()) :: ManagedAgents.result()
  def update(client, id, params) when is_id(id) and is_map(params),
    do: HTTP.post(client, "agents/#{HTTP.segment(id)}", params)

  @doc "Lists agents. Options: `limit`, `page`, `include_archived`, `created_at: [gte: …, lte: …]`."
  @spec list(Req.Request.t(), keyword()) :: ManagedAgents.result()
  def list(client, opts \\ []) when is_list(opts), do: HTTP.get(client, "agents", opts)

  @doc "Archives an agent (sets `archived_at`; there is no delete)."
  @spec archive(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def archive(client, id) when is_id(id), do: HTTP.post(client, "agents/#{HTTP.segment(id)}/archive", nil)

  @doc "Lists an agent's versions, newest first. Options: `limit`, `page`."
  @spec list_versions(Req.Request.t(), String.t(), keyword()) :: ManagedAgents.result()
  def list_versions(client, id, opts \\ []) when is_id(id) and is_list(opts),
    do: HTTP.get(client, "agents/#{HTTP.segment(id)}/versions", opts)
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/managed_agents/agents_test.exs`
Expected: 9 tests, 0 failures.

- [ ] **Step 5: Quality gates**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/managed_agents/agents.ex test/managed_agents/agents_test.exs
git commit -m "feat(managed-agents): Agents (create/get/update/list/archive/list_versions)"
```

---

### Task 3: Environments

**Files:**
- Create: `lib/claudio/managed_agents/environments.ex`
- Test: `test/managed_agents/environments_test.exs`

**Interfaces:**
- Consumes: Task 1's `HTTP` and test support.
- Produces (all `Claudio.ManagedAgents.result()`): `Environments.create(client, params)`, `get(client, id)`, `update(client, id, params)`, `list(client, opts \\ [])`, `archive(client, id)`, `delete(client, id)`.

- [ ] **Step 1: Write the failing tests**

`test/managed_agents/environments_test.exs`:

```elixir
Code.require_file("support.exs", __DIR__)

defmodule Claudio.ManagedAgents.EnvironmentsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.ManagedAgents.Environments

  setup :setup_client

  @config %{"type" => "cloud", "networking" => %{"type" => "unrestricted"}}

  test "create posts the params", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/environments", %{"id" => "env_1"}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"name" => "default", "config" => @config}
    end)

    assert {:ok, %{"id" => "env_1"}} = Environments.create(client, %{name: "default", config: @config})
  end

  test "get", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/environments/env_1", %{"id" => "env_1", "state" => "active"})
    assert {:ok, %{"state" => "active"}} = Environments.get(client, "env_1")
  end

  test "update posts to the environment path", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/environments/env_1", %{"id" => "env_1"}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"description" => "d"}
    end)

    assert {:ok, _} = Environments.update(client, "env_1", %{description: "d"})
  end

  test "list encodes options", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/environments", %{"data" => []}, fn _c, query, _r ->
      assert query == [{"limit", "5"}, {"page", "page_abc"}]
    end)

    assert {:ok, %{"data" => []}} = Environments.list(client, limit: 5, page: "page_abc")
  end

  test "archive posts no body", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/environments/env_1/archive", %{"id" => "env_1"}, fn _c, _q, raw ->
      assert raw == ""
    end)

    assert {:ok, _} = Environments.archive(client, "env_1")
  end

  test "delete", %{client: client, bypass: bypass} do
    expect_call(bypass, "DELETE", "/environments/env_1", %{"id" => "env_1", "type" => "environment_deleted"})
    assert {:ok, %{"type" => "environment_deleted"}} = Environments.delete(client, "env_1")
  end

  test "an empty id raises FunctionClauseError", %{client: client} do
    assert_raise FunctionClauseError, fn -> Environments.delete(client, "") end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/managed_agents/environments_test.exs`
Expected: compile error — `Claudio.ManagedAgents.Environments` undefined.

- [ ] **Step 3: Implement `lib/claudio/managed_agents/environments.ex`**

```elixir
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
  def get(client, id) when is_id(id), do: HTTP.get(client, "environments/#{HTTP.segment(id)}", [])

  @doc "Updates an environment (`POST /v1/environments/{id}`)."
  @spec update(Req.Request.t(), String.t(), map()) :: ManagedAgents.result()
  def update(client, id, params) when is_id(id) and is_map(params),
    do: HTTP.post(client, "environments/#{HTTP.segment(id)}", params)

  @doc "Lists environments. Options: `limit`, `page`, `include_archived`."
  @spec list(Req.Request.t(), keyword()) :: ManagedAgents.result()
  def list(client, opts \\ []) when is_list(opts), do: HTTP.get(client, "environments", opts)

  @doc "Archives an environment (read-only; existing sessions continue)."
  @spec archive(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def archive(client, id) when is_id(id),
    do: HTTP.post(client, "environments/#{HTTP.segment(id)}/archive", nil)

  @doc "Deletes an environment. Fails while any session references it."
  @spec delete(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def delete(client, id) when is_id(id), do: HTTP.delete(client, "environments/#{HTTP.segment(id)}")
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/managed_agents/environments_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 5: Quality gates**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/managed_agents/environments.ex test/managed_agents/environments_test.exs
git commit -m "feat(managed-agents): Environments (create/get/update/list/archive/delete)"
```

---

### Task 4: Sessions, events and resources

**Files:**
- Create: `lib/claudio/managed_agents/sessions.ex`
- Test: `test/managed_agents/sessions_test.exs`

**Interfaces:**
- Consumes: Task 1's `HTTP` and test support.
- Produces (all `Claudio.ManagedAgents.result()`):
  - `Sessions.create(client, params)`, `get(client, id)`, `update(client, id, params)`, `list(client, opts \\ [])`, `archive(client, id)`, `delete(client, id)`
  - `Sessions.send_events(client, id, events :: [map()])` — body `%{"events" => events}`; non-list → `ArgumentError`
  - `Sessions.list_events(client, id, opts \\ [])`
  - `Sessions.add_resource(client, id, resource :: map())`, `list_resources(client, id, opts \\ [])`, `get_resource(client, id, rid)`, `update_resource(client, id, rid, params :: map())`, `delete_resource(client, id, rid)`

- [ ] **Step 1: Write the failing tests**

`test/managed_agents/sessions_test.exs`:

```elixir
Code.require_file("support.exs", __DIR__)

defmodule Claudio.ManagedAgents.SessionsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.ManagedAgents.Sessions

  setup :setup_client

  describe "sessions" do
    test "create posts the params", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions", %{"id" => "sesn_1", "status" => "idle"}, fn _c, _q, raw ->
        assert Jason.decode!(raw) == %{"agent" => "agent_1", "environment_id" => "env_1"}
      end)

      assert {:ok, %{"status" => "idle"}} =
               Sessions.create(client, %{agent: "agent_1", environment_id: "env_1"})
    end

    test "get", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions/sesn_1", %{"id" => "sesn_1"})
      assert {:ok, %{"id" => "sesn_1"}} = Sessions.get(client, "sesn_1")
    end

    test "update posts to the session path", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions/sesn_1", %{"title" => "t"}, fn _c, _q, raw ->
        assert Jason.decode!(raw) == %{"title" => "t", "metadata" => %{"k" => "v"}}
      end)

      assert {:ok, %{"title" => "t"}} = Sessions.update(client, "sesn_1", %{title: "t", metadata: %{k: "v"}})
    end

    test "list encodes bracketed filters", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions", %{"data" => []}, fn _c, query, _r ->
        assert query == [
                 {"statuses[]", "idle"},
                 {"statuses[]", "running"},
                 {"created_at[gte]", "2026-09-01T00:00:00Z"},
                 {"agent_id", "agent_1"}
               ]
      end)

      assert {:ok, _} =
               Sessions.list(client,
                 statuses: ["idle", "running"],
                 created_at: [gte: ~U[2026-09-01 00:00:00Z]],
                 agent_id: "agent_1"
               )
    end

    test "archive posts no body; delete issues DELETE", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions/sesn_1/archive", %{"id" => "sesn_1"}, fn _c, _q, raw ->
        assert raw == ""
      end)

      expect_call(bypass, "DELETE", "/sessions/sesn_1", %{"type" => "session_deleted"})

      assert {:ok, _} = Sessions.archive(client, "sesn_1")
      assert {:ok, %{"type" => "session_deleted"}} = Sessions.delete(client, "sesn_1")
    end
  end

  describe "events" do
    test "send_events wraps the list in an events body", %{client: client, bypass: bypass} do
      event = %{type: "user.message", content: [%{type: "text", text: "Hi"}]}

      expect_call(bypass, "POST", "/sessions/sesn_1/events", %{"data" => []}, fn _c, _q, raw ->
        assert Jason.decode!(raw) == %{
                 "events" => [
                   %{"type" => "user.message", "content" => [%{"type" => "text", "text" => "Hi"}]}
                 ]
               }
      end)

      assert {:ok, _} = Sessions.send_events(client, "sesn_1", [event])
    end

    test "send_events with a non-list raises ArgumentError naming the function", %{client: client} do
      assert_raise ArgumentError, ~r/send_events\/3.*%\{type: "user.message"\}/, fn ->
        Sessions.send_events(client, "sesn_1", %{type: "user.message"})
      end
    end

    test "list_events encodes types[] and order", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions/sesn_1/events", %{"data" => []}, fn _c, query, _r ->
        assert query == [{"types[]", "agent.message"}, {"order", "desc"}, {"limit", "10"}]
      end)

      assert {:ok, %{"data" => []}} =
               Sessions.list_events(client, "sesn_1", types: ["agent.message"], order: :desc, limit: 10)
    end
  end

  describe "resources" do
    test "add_resource posts the resource", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions/sesn_1/resources", %{"id" => "sesrsc_1"}, fn _c, _q, raw ->
        assert Jason.decode!(raw) == %{"type" => "file", "file_id" => "file_1"}
      end)

      assert {:ok, %{"id" => "sesrsc_1"}} =
               Sessions.add_resource(client, "sesn_1", %{type: "file", file_id: "file_1"})
    end

    test "list_resources / get_resource", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions/sesn_1/resources", %{"data" => []})
      expect_call(bypass, "GET", "/sessions/sesn_1/resources/sesrsc_1", %{"id" => "sesrsc_1"})

      assert {:ok, %{"data" => []}} = Sessions.list_resources(client, "sesn_1")
      assert {:ok, %{"id" => "sesrsc_1"}} = Sessions.get_resource(client, "sesn_1", "sesrsc_1")
    end

    test "update_resource posts the params", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions/sesn_1/resources/sesrsc_1", %{"id" => "sesrsc_1"}, fn _c, _q, raw ->
        assert Jason.decode!(raw) == %{"authorization_token" => "ghp_x"}
      end)

      assert {:ok, _} =
               Sessions.update_resource(client, "sesn_1", "sesrsc_1", %{authorization_token: "ghp_x"})
    end

    test "delete_resource", %{client: client, bypass: bypass} do
      expect_call(bypass, "DELETE", "/sessions/sesn_1/resources/sesrsc_1", %{
        "type" => "session_resource_deleted"
      })

      assert {:ok, %{"type" => "session_resource_deleted"}} =
               Sessions.delete_resource(client, "sesn_1", "sesrsc_1")
    end

    test "an empty resource id raises FunctionClauseError", %{client: client} do
      assert_raise FunctionClauseError, fn -> Sessions.get_resource(client, "sesn_1", "") end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/managed_agents/sessions_test.exs`
Expected: compile error — `Claudio.ManagedAgents.Sessions` undefined.

- [ ] **Step 3: Implement `lib/claudio/managed_agents/sessions.ex`**

```elixir
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

  @doc "Creates a session. `agent` (id or `%{type: \"agent\", id:, version:}`) and `environment_id` are required by the API."
  @spec create(Req.Request.t(), map()) :: ManagedAgents.result()
  def create(client, params) when is_map(params), do: HTTP.post(client, "sessions", params)

  @doc "Retrieves a session (status, resolved agent snapshot, usage, stats)."
  @spec get(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def get(client, id) when is_id(id), do: HTTP.get(client, path(id), [])

  @doc "Updates a session: `title`, `metadata`, `budget`, and (while idle) `agent.tools` / `agent.mcp_servers`."
  @spec update(Req.Request.t(), String.t(), map()) :: ManagedAgents.result()
  def update(client, id, params) when is_id(id) and is_map(params), do: HTTP.post(client, path(id), params)

  @doc """
  Lists sessions. Options include `statuses: [...]`, `created_at: [gte: …]`, `agent_id`,
  `agent_version`, `deployment_id`, `memory_store_id`, `include_archived`, `order`, `limit`, `page`.
  """
  @spec list(Req.Request.t(), keyword()) :: ManagedAgents.result()
  def list(client, opts \\ []) when is_list(opts), do: HTTP.get(client, "sessions", opts)

  @doc "Archives a session (keeps history, blocks new events). Not allowed while `running`."
  @spec archive(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def archive(client, id) when is_id(id), do: HTTP.post(client, path(id) <> "/archive", nil)

  @doc "Deletes a session permanently. Not allowed while `running`."
  @spec delete(Req.Request.t(), String.t()) :: ManagedAgents.result()
  def delete(client, id) when is_id(id), do: HTTP.delete(client, path(id))

  @doc "Sends events (a list of event maps) to a session: `POST …/events` with `%{\"events\" => events}`."
  @spec send_events(Req.Request.t(), String.t(), [map()]) :: ManagedAgents.result()
  def send_events(client, id, events) when is_id(id) and is_list(events),
    do: HTTP.post(client, path(id) <> "/events", %{"events" => events})

  def send_events(_client, _id, events) when not is_list(events) do
    raise ArgumentError,
          "Claudio.ManagedAgents.Sessions.send_events/3 expects a list of event maps; " <>
            "got: #{inspect(events)}"
  end

  @doc "Lists a session's events. Options: `types: [...]`, `created_at: [...]`, `order`, `limit`, `page`."
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
  @spec update_resource(Req.Request.t(), String.t(), String.t(), map()) :: ManagedAgents.result()
  def update_resource(client, id, rid, params) when is_id(id) and is_id(rid) and is_map(params),
    do: HTTP.post(client, resource_path(id, rid), params)

  @doc "Removes a resource from a session."
  @spec delete_resource(Req.Request.t(), String.t(), String.t()) :: ManagedAgents.result()
  def delete_resource(client, id, rid) when is_id(id) and is_id(rid),
    do: HTTP.delete(client, resource_path(id, rid))

  defp path(id), do: "sessions/#{HTTP.segment(id)}"
  defp resource_path(id, rid), do: path(id) <> "/resources/#{HTTP.segment(rid)}"
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/managed_agents/sessions_test.exs`
Expected: 13 tests, 0 failures.

- [ ] **Step 5: Quality gates**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean. If Credo flags the long `@doc` line in `create/2`, convert it to a heredoc.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/managed_agents/sessions.ex test/managed_agents/sessions_test.exs
git commit -m "feat(managed-agents): Sessions with events and resources"
```

---

### Task 5: `Claudio.ManagedAgents.stream/2`

**Files:**
- Modify: `lib/claudio/managed_agents.ex` (add `stream/2` + its docs)
- Test: `test/managed_agents/managed_agents_test.exs`

**Interfaces:**
- Consumes: any list function returning `Claudio.ManagedAgents.result()` (Tasks 2–4).
- Produces: `Claudio.ManagedAgents.stream((keyword() -> result()), keyword()) :: Enumerable.t()` — lazy; emits `"data"` items; threads `page:`; stops when `"next_page"` is absent or `nil`; raises on errors.

- [ ] **Step 1: Write the failing tests**

`test/managed_agents/managed_agents_test.exs`:

```elixir
Code.require_file("support.exs", __DIR__)

defmodule Claudio.ManagedAgentsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.APIError
  alias Claudio.ManagedAgents
  alias Claudio.ManagedAgents.Agents

  setup :setup_client

  # Serves `pages` (a map from the incoming `page` param — nil for the first call — to the
  # response body), asserting `limit` is kept on every call, and counts calls.
  defp serve_pages(bypass, pages) do
    counter = :counters.new(1, [])

    Bypass.expect(bypass, "GET", "/agents", fn conn ->
      :counters.add(counter, 1, 1)
      params = URI.decode_query(conn.query_string)
      assert params["limit"] == "2"

      case Map.fetch!(pages, params["page"]) do
        {:error, status} ->
          json(conn, status, %{"type" => "error", "error" => %{"type" => "api_error", "message" => "boom"}})

        body ->
          json(conn, 200, body)
      end
    end)

    counter
  end

  defp list_fun(client), do: fn opts -> Agents.list(client, opts) end

  test "walks every page, threading next_page", %{client: client, bypass: bypass} do
    serve_pages(bypass, %{
      nil => %{"data" => [%{"id" => "a1"}, %{"id" => "a2"}], "next_page" => "p2"},
      "p2" => %{"data" => [%{"id" => "a3"}, %{"id" => "a4"}], "next_page" => "p3"},
      "p3" => %{"data" => [%{"id" => "a5"}], "next_page" => nil}
    })

    ids = client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.map(& &1["id"])
    assert ids == ["a1", "a2", "a3", "a4", "a5"]
  end

  test "stops when next_page is absent", %{client: client, bypass: bypass} do
    counter =
      serve_pages(bypass, %{
        nil => %{"data" => [%{"id" => "a1"}], "next_page" => "p2"},
        "p2" => %{"data" => [%{"id" => "a2"}]}
      })

    assert client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.count() == 2
    assert :counters.get(counter, 1) == 2
  end

  test "an empty first page yields nothing", %{client: client, bypass: bypass} do
    serve_pages(bypass, %{nil => %{"data" => []}})
    assert client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.to_list() == []
  end

  test "is lazy: take/2 fetches only the pages it needs", %{client: client, bypass: bypass} do
    counter =
      serve_pages(bypass, %{
        nil => %{"data" => [%{"id" => "a1"}, %{"id" => "a2"}], "next_page" => "p2"},
        "p2" => %{"data" => [%{"id" => "a3"}], "next_page" => nil}
      })

    assert client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.take(2) |> length() == 2
    assert :counters.get(counter, 1) == 1
  end

  test "a page: in the initial opts is used for the first fetch", %{client: client, bypass: bypass} do
    serve_pages(bypass, %{"p2" => %{"data" => [%{"id" => "a3"}], "next_page" => nil}})

    ids = client |> list_fun() |> ManagedAgents.stream(limit: 2, page: "p2") |> Enum.map(& &1["id"])
    assert ids == ["a3"]
  end

  test "an error on page 2 raises after page 1's items were emitted", %{client: client, bypass: bypass} do
    serve_pages(bypass, %{
      nil => %{"data" => [%{"id" => "a1"}], "next_page" => "p2"},
      "p2" => {:error, 400}
    })

    stream =
      client
      |> list_fun()
      |> ManagedAgents.stream(limit: 2)
      |> Stream.each(&send(self(), {:item, &1["id"]}))

    assert_raise APIError, ~r/boom/, fn -> Enum.to_list(stream) end
    assert_received {:item, "a1"}
  end

  test "a non-exception error raises RuntimeError with the reason" do
    stream = ManagedAgents.stream(fn _opts -> {:error, :nxdomain} end)
    assert_raise RuntimeError, ~r/:nxdomain/, fn -> Enum.to_list(stream) end
  end

  test "a body without a data list raises ArgumentError" do
    stream = ManagedAgents.stream(fn _opts -> {:ok, %{"id" => "agent_1"}} end)
    assert_raise ArgumentError, ~r/stream\/2.*"data"/, fn -> Enum.to_list(stream) end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/managed_agents/managed_agents_test.exs`
Expected: failures — `function Claudio.ManagedAgents.stream/2 is undefined`.

- [ ] **Step 3: Add `stream/2` to `lib/claudio/managed_agents.ex`**

Append to the moduledoc (before the closing `"""`):

```markdown
  To walk every page lazily, wrap any list function in `stream/2`:

      Claudio.ManagedAgents.stream(fn opts -> Claudio.ManagedAgents.Agents.list(client, opts) end, limit: 100)
      |> Enum.take(250)
```

Add below `@type result`:

```elixir
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
        case Map.get(body, "next_page") do
          nil -> {items, :done}
          cursor when is_binary(cursor) -> {items, {:fetch, Keyword.put(opts, :page, cursor)}}
        end

      {:ok, other} ->
        raise ArgumentError,
              "Claudio.ManagedAgents.stream/2 expects the list function to return " <>
                "{:ok, %{\"data\" => [...]}}; got: {:ok, #{inspect(other)}}"

      {:error, %{__exception__: true} = exception} ->
        raise exception

      {:error, reason} ->
        raise RuntimeError, "Claudio.ManagedAgents.stream/2: fetching a page failed: #{inspect(reason)}"
    end
  end
```

A `"next_page"` that is neither `nil` nor a string hits a `CaseClauseError` — intended (an API
shape change should crash, not end the stream silently).

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/managed_agents/managed_agents_test.exs`
Expected: 8 tests, 0 failures.

- [ ] **Step 5: Quality gates**

Run: `mix format && mix compile --warnings-as-errors && mix credo --strict && mix test`
Expected: clean. If Credo flags nesting in `fetch_page/3`, extract the `next_page` `case` into `defp next_state(body, opts)`.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/managed_agents.ex test/managed_agents/managed_agents_test.exs
git commit -m "feat(managed-agents): lazy cursor pagination with ManagedAgents.stream/2"
```

---

### Task 6: Live integration test

**Files:**
- Create: `test/integration/managed_agents_integration_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1–5, `Claudio.Files.upload/3` and `Claudio.Files.delete/2`, `Claudio.IntegrationHelper.skip_if_no_api_key/0` and `create_client/0`.

No model is called: the session stays `idle` (F6), so the run costs no tokens. It mirrors probes P2–P9.

- [ ] **Step 1: Write the test**

```elixir
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
      ManagedAgents.stream(fn opts -> Agents.list_versions(client, agent["id"], opts) end, limit: 1)
      |> Enum.map(& &1["version"])

    assert versions == [2, 1]

    # Environment
    {:ok, env} =
      Environments.create(client, %{name: tag, config: %{type: "cloud", networking: %{type: "unrestricted"}}})

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

    {:ok, updated} = Sessions.update(client, session["id"], %{title: tag, metadata: %{suite: "it"}})
    assert updated["title"] == tag
    assert updated["metadata"] == %{"suite" => "it"}

    assert {:ok, %{"data" => []}} = Sessions.list_events(client, session["id"])

    {:ok, listed} = Sessions.list(client, statuses: ["idle"], agent_id: agent["id"])
    assert Enum.any?(listed["data"], &(&1["id"] == session["id"]))

    # File resource: upload, mount, inspect, remove
    {:ok, file} = Files.upload(client, "claudio integration\n", filename: "#{tag}.txt", content_type: "text/plain")
    on_exit(fn -> Files.delete(client, file["id"]) end)

    {:ok, res} = Sessions.add_resource(client, session["id"], %{type: "file", file_id: file["id"]})
    assert "sesrsc_" <> _ = res["id"]
    # The API mounts a session-scoped copy: a new file id, mount path keeps the original (F11).
    refute res["file_id"] == file["id"]
    assert res["mount_path"] == "/mnt/session/uploads/#{file["id"]}"

    {:ok, %{"data" => resources}} = Sessions.list_resources(client, session["id"])
    assert Enum.sort(Enum.map(resources, & &1["type"])) == ["file", "github_repository"]

    assert {:ok, %{"id" => _}} = Sessions.get_resource(client, session["id"], res["id"])

    assert {:ok, %{"type" => "github_repository"}} =
             Sessions.update_resource(client, session["id"], repo_rid, %{authorization_token: "ghp_dummy_token"})

    assert {:ok, %{"type" => "session_resource_deleted"}} =
             Sessions.delete_resource(client, session["id"], res["id"])

    assert {:error, %APIError{status_code: 404}} = Sessions.get_resource(client, session["id"], res["id"])
  end
end
```

- [ ] **Step 2: Run it live**

Run: `mix test test/integration/managed_agents_integration_test.exs --include integration`
Expected: 1 test, 0 failures. If any assertion fails on a response shape, **stop and report the raw response** — it means the API drifted from the spec's facts (F2–F11); don't loosen the assertion.

- [ ] **Step 3: Verify cleanup left nothing behind**

Run: `mix run -e 'c = Claudio.Client.new(%{token: System.fetch_env!("ANTHROPIC_API_KEY"), version: "2023-06-01"}); {:ok, %{"data" => d}} = Claudio.ManagedAgents.Environments.list(c, limit: 100); IO.inspect(Enum.filter(d, &String.starts_with?(&1["name"], "claudio-it-")))'`
Expected: `[]` (the environment was deleted; agents can only be archived).

- [ ] **Step 4: Commit**

```bash
git add test/integration/managed_agents_integration_test.exs
git commit -m "test(managed-agents): live integration flow (no model call)"
```

---

### Task 7: Docs, ExDoc group, full gates

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased]` → `### Added`, line ~10)
- Modify: `CLAUDE.md` (new section before `### Message Batches API`; module tree)
- Modify: `README.md` (new `### Managed Agents (beta)` after `### Autonomous Agents`, line ~342)
- Modify: `mix.exs` (`groups_for_modules`)

- [ ] **Step 1: CHANGELOG** — add under `## [Unreleased]` → `### Added`:

```markdown
- **Managed Agents foundation** (beta `managed-agents-2026-04-01`, attached per request):
  `Claudio.ManagedAgents.Agents` (create / get incl. `version:` / update / list / archive /
  list_versions), `Claudio.ManagedAgents.Environments` (create / get / update / list / archive /
  delete), `Claudio.ManagedAgents.Sessions` (create / get / update / list / archive / delete,
  `send_events/3`, `list_events/3`, session resources). List options encode the API's bracketed
  filters (`statuses: [...]` → `statuses[]=…`, `created_at: [gte: dt]` → `created_at[gte]=…`).
  `Claudio.ManagedAgents.stream/2` walks cursor-paged lists lazily. Raw-map returns, like
  `Claudio.Skills`.
```

- [ ] **Step 2: CLAUDE.md** — insert before `### Message Batches API (lib/claudio/batches.ex)`:

```markdown
### Managed Agents (lib/claudio/managed_agents/) — beta
Server-hosted agents (`managed-agents-2026-04-01`, merged into the client's betas per request by the private `Claudio.ManagedAgents.HTTP`). Raw-map returns (`{:ok, map()}` / `{:error, APIError}`), no local body validation. Roadmap: `docs/superpowers/specs/2026-09-30-managed-agents-roadmap.md` (MA1 shipped; MA2 run loop + `Claudio.Agent` deprecation, MA3 deployments/vaults/memory stores/threads, MA4 dreams/work queue/webhooks; 0.8.0 after MA4).
- `Agents`: create, get (`version:`), update (body `version` = optimistic check, stale → 409), list, archive (no delete), list_versions
- `Environments`: create, get, update, list, archive, delete (only when unreferenced)
- `Sessions`: CRUD + archive/delete (not while `running`), `send_events/3` (list of event maps), `list_events/3`, resources (mid-session add accepts only `file`, which needs the agent toolset's `read`; update = GitHub token rotation)
- List options: list → `key[]`, keyword → `key[sub]`, `DateTime` → ISO 8601; `nil` / `[]` / maps raise. `Claudio.ManagedAgents.stream/2` pages lazily (stops on absent or nil `next_page`, raises on errors)
```

and add to the module tree under `├── files.ex`:

```
    ├── managed_agents.ex      # Managed Agents overview + stream/2
    ├── managed_agents/        # http (private), agents, environments, sessions
```

- [ ] **Step 3: README** — insert after the `### Autonomous Agents` section (before `### MCP (Model Context Protocol)`):

````markdown
### Managed Agents (beta)

Server-hosted agents that run in Anthropic's sandbox. Claudio attaches the
`managed-agents-2026-04-01` beta per request.

```elixir
alias Claudio.ManagedAgents.{Agents, Environments, Sessions}

{:ok, agent} = Agents.create(client, %{name: "researcher", model: "claude-opus-5-5",
                                       tools: [%{type: "agent_toolset_20260401"}]})
{:ok, env} = Environments.create(client, %{name: "default",
                                           config: %{type: "cloud", networking: %{type: "unrestricted"}}})
{:ok, session} = Sessions.create(client, %{agent: agent["id"], environment_id: env["id"]})

{:ok, _} = Sessions.send_events(client, session["id"], [
  %{type: "user.message", content: [%{type: "text", text: "List the files in the repo."}]}
])

{:ok, %{"data" => events}} = Sessions.list_events(client, session["id"])

# Every page, lazily:
Claudio.ManagedAgents.stream(fn opts -> Sessions.list(client, opts) end, statuses: ["idle"])
|> Enum.map(& &1["id"])
```

A typed event stream and a run loop for custom tools and confirmations are planned next.
````

- [ ] **Step 4: mix.exs** — add to `groups_for_modules` after the `"Skills API"` entry:

```elixir
        "Managed Agents (beta)": [
          Claudio.ManagedAgents,
          Claudio.ManagedAgents.Agents,
          Claudio.ManagedAgents.Environments,
          Claudio.ManagedAgents.Sessions
        ],
```

- [ ] **Step 5: Full gates**

Run: `mix precommit && mix docs --warnings-as-errors`
Expected: compile clean, no unused deps, formatted, Credo strict clean, Dialyzer 0 warnings, all tests pass, ExDoc no warnings. If Dialyzer reports on `HTTP.post/3`'s `nil` clause or `stream/2`'s spec, fix the spec — don't add an ignore.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md CLAUDE.md README.md mix.exs
git commit -m "docs(managed-agents): CHANGELOG, CLAUDE.md, README, ExDoc group for MA1"
```

- [ ] **Step 7: Update the roadmap status**

In `docs/superpowers/specs/2026-09-30-managed-agents-roadmap.md`, change the MA1 row's status to `implemented (MA1 PR); spec 2026-09-30-ma1-foundation-design.md`, then:

```bash
git add docs/superpowers/specs/2026-09-30-managed-agents-roadmap.md
git commit -m "docs: mark MA1 implemented in the Managed Agents roadmap"
```
