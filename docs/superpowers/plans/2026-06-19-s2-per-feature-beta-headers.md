# S2 — Per-feature beta-header management — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `Request` feature setters declare the `anthropic-beta` flag they require and have the send path merge those flags into the header, so beta-gated features stop silently `400`-ing.

**Architecture:** A `%Request{}` carries a `betas` list; feature setters self-declare via `add_beta/2`; `Claudio.Client.with_betas/2` is the single point that unions declared betas onto the client's `anthropic-beta` header; `Messages.create/2`, `Messages.count_tokens/2`, and `Batches.create/2` call it before posting. One feature is wired now (`set_context_management/2`); a public `add_beta/2` covers everything else.

**Tech Stack:** Elixir, Req (HTTP), Bypass (unit HTTP mocking), ExUnit. Design spec: `docs/superpowers/specs/2026-06-19-s2-per-feature-beta-headers-design.md`.

## Global Constraints

- **Additive only — no breaking changes.** `betas` defaults to `[]`; `with_betas(client, [])` is a no-op, so any path producing no betas is byte-identical to today.
- **`Request.to_map/1` must never emit `betas`.** Betas are an HTTP header, never a body field. A unit test guards this.
- **Single merge point:** all three call sites use `Claudio.Client.with_betas/2`. Do not inline header munging anywhere else.
- **Beta string (verbatim):** `context-management-2025-06-27`.
- **Do NOT auto-wire MCP** (`mcp-client-2025-11-20` + `mcp_toolset`) — out of scope; deferred to its own spec. The raw-map send paths are also unchanged (callers manage betas via `Client.new`).
- **`APIError` field is `:status_code`** (not `:status`).
- **Git:** add files individually (never `git add .`); conventional-commit messages; **no AI attribution / Co-Authored-By lines**.
- **Tests:** unit tests use Bypass with `async: true`; the live test is `@tag :integration`, excluded by default, run with `mix test --include integration`.

---

### Task 1: `Request` — `betas` field, `add_beta/2`, `required_betas/1`

**Files:**
- Modify: `lib/claudio/messages/request.ex` (`@type t` ~22-40; `defstruct` ~42-60; new functions after `set_service_tier/2` ~521)
- Test: `test/request_test.exs`

**Interfaces:**
- Produces:
  - struct field `betas: [String.t()]`, default `[]`
  - `Request.add_beta(t(), String.t()) :: t()` — append-if-absent, order-preserving
  - `Request.required_betas(t()) :: [String.t()]`

- [ ] **Step 1: Write the failing tests**

Add to `test/request_test.exs` (after the `new/1` describe):

```elixir
describe "betas / add_beta/2 / required_betas/1" do
  test "a new request has no betas" do
    assert Request.new("claude-3-5-sonnet-20241022") |> Request.required_betas() == []
  end

  test "add_beta/2 records a beta string" do
    request =
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_beta("context-management-2025-06-27")

    assert Request.required_betas(request) == ["context-management-2025-06-27"]
  end

  test "add_beta/2 dedups and preserves insertion order" do
    request =
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_beta("a-2025-01-01")
      |> Request.add_beta("b-2025-01-01")
      |> Request.add_beta("a-2025-01-01")

    assert Request.required_betas(request) == ["a-2025-01-01", "b-2025-01-01"]
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs --only_describe "betas / add_beta/2 / required_betas/1"` (or simply `mix test test/request_test.exs`)
Expected: FAIL — `function Claudio.Messages.Request.add_beta/2 is undefined` (and `required_betas/1`).

- [ ] **Step 3: Add the struct field and typespec**

In `@type t`, change the last field line so it reads:

```elixir
          service_tier: String.t() | nil,
          betas: [String.t()]
        }
```

In `defstruct`, change the tail so it reads:

```elixir
    :service_tier,
    betas: []
  ]
```

(`:atom` entries default to `nil`; `betas: []` defaults to an empty list. `new/1` needs no change — the struct default applies.)

- [ ] **Step 4: Add the two functions**

Insert immediately after `set_service_tier/2` (before the `to_map/1` doc):

```elixir
  @doc """
  Adds a beta feature flag the request requires.

  Beta flags are merged into the `anthropic-beta` request header at send time
  (see `Claudio.Client.with_betas/2`). Use this to opt into beta-gated features
  the library does not model with a dedicated setter.

  Duplicates are ignored; insertion order is preserved.

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.add_beta("context-management-2025-06-27")
  """
  @spec add_beta(t(), String.t()) :: t()
  def add_beta(%__MODULE__{betas: betas} = request, beta) when is_binary(beta) do
    if beta in betas do
      request
    else
      %{request | betas: betas ++ [beta]}
    end
  end

  @doc """
  Returns the list of beta feature flags this request requires.
  """
  @spec required_betas(t()) :: [String.t()]
  def required_betas(%__MODULE__{betas: betas}), do: betas
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/request_test.exs`
Expected: PASS (all, including the existing tests).

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(request): add betas field, add_beta/2, required_betas/1"
```

---

### Task 2: Wire `set_context_management/2` to declare its beta

**Files:**
- Modify: `lib/claudio/messages/request.ex` (`set_context_management/2` ~477-480)
- Test: `test/request_test.exs`

**Interfaces:**
- Consumes: `add_beta/2`, `required_betas/1`, `to_map/1` (Task 1)
- Produces: `set_context_management/2` now adds `"context-management-2025-06-27"` to `betas`

- [ ] **Step 1: Write the failing tests**

Add to `test/request_test.exs`:

```elixir
describe "set_context_management/2 beta wiring" do
  test "declares the context-management beta" do
    request =
      Request.new("claude-opus-4-8")
      |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

    assert "context-management-2025-06-27" in Request.required_betas(request)
  end

  test "to_map includes context_management but never betas" do
    request =
      Request.new("claude-opus-4-8")
      |> Request.add_message(:user, "hi")
      |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

    map = Request.to_map(request)

    assert map["context_management"] == %{"edits" => [%{"type" => "clear_tool_uses_20250919"}]}
    refute Map.has_key?(map, "betas")
    refute Map.has_key?(map, "anthropic-beta")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs`
Expected: FAIL — `"context-management-2025-06-27" in []` is false.

- [ ] **Step 3: Wire the setter**

Replace `set_context_management/2`:

```elixir
  def set_context_management(%__MODULE__{} = request, config) when is_map(config) do
    %{request | context_management: config}
    |> add_beta("context-management-2025-06-27")
  end
```

(`to_map/1` is unchanged — it has no `betas` line, which is exactly what the second test asserts.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/request_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(request): set_context_management declares context-management beta"
```

---

### Task 3: `Client.with_betas/2` — the single merge point

**Files:**
- Modify: `lib/claudio/client.ex` (add public function after `new/2` ~115)
- Test: `test/client_test.exs`

**Interfaces:**
- Produces: `Claudio.Client.with_betas(Req.Request.t(), [String.t()]) :: Req.Request.t()` — unions `betas` onto the existing `anthropic-beta` header (deduped, order preserved); empty list is a no-op.

- [ ] **Step 1: Write the failing tests**

Add to `test/client_test.exs` (a new top-level `describe`, outside the "timeout configuration" describe):

```elixir
describe "with_betas/2" do
  test "is a no-op for an empty beta list" do
    client = Claudio.Client.new(%{token: "t", version: "2023-06-01", beta: ["a-2025-01-01"]})
    assert Claudio.Client.with_betas(client, []) == client
  end

  test "unions new betas onto the existing header" do
    client = Claudio.Client.new(%{token: "t", version: "2023-06-01", beta: ["a-2025-01-01"]})
    merged = Claudio.Client.with_betas(client, ["b-2025-01-01"])
    assert merged.headers["anthropic-beta"] == ["a-2025-01-01,b-2025-01-01"]
  end

  test "sets the header when the client had none" do
    client = Claudio.Client.new(%{token: "t", version: "2023-06-01"})
    merged = Claudio.Client.with_betas(client, ["b-2025-01-01"])
    assert merged.headers["anthropic-beta"] == ["b-2025-01-01"]
  end

  test "dedups betas already present" do
    client = Claudio.Client.new(%{token: "t", version: "2023-06-01", beta: ["a-2025-01-01"]})
    merged = Claudio.Client.with_betas(client, ["a-2025-01-01", "b-2025-01-01"])
    assert merged.headers["anthropic-beta"] == ["a-2025-01-01,b-2025-01-01"]
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/client_test.exs`
Expected: FAIL — `function Claudio.Client.with_betas/2 is undefined`.

- [ ] **Step 3: Implement `with_betas/2`**

Insert immediately after the `new/2` function (before `defp merge_defaults`):

```elixir
  @doc """
  Merges additional beta feature flags into a client's `anthropic-beta` header.

  Unions `betas` with whatever the client was built with at `new/2` (deduped,
  insertion order preserved). An empty list returns the client unchanged. Used
  by the send path to attach per-request betas declared via
  `Claudio.Messages.Request.add_beta/2`.
  """
  @spec with_betas(Req.Request.t(), [String.t()]) :: Req.Request.t()
  def with_betas(client, []), do: client

  def with_betas(client, betas) when is_list(betas) do
    existing =
      client
      |> Req.Request.get_header("anthropic-beta")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    merged = Enum.uniq(existing ++ betas)
    Req.Request.put_header(client, "anthropic-beta", Enum.join(merged, ","))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/client_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/client.ex test/client_test.exs
git commit -m "feat(client): add with_betas/2 to merge per-request beta headers"
```

---

### Task 4: `Messages.create/2` and `count_tokens/2` merge declared betas

**Files:**
- Modify: `lib/claudio/messages.ex` (`create/2` `%Request{}` clause ~146-148; `count_tokens/2` `%Request{}` clause ~210-219)
- Test: `test/messages_test.exs`

**Interfaces:**
- Consumes: `Request.required_betas/1` (Task 1), `Claudio.Client.with_betas/2` (Task 3)

The existing `test/messages_test.exs` `setup` builds a client with `beta: ["token-counting-2024-11-01"]`. These tests reuse it and assert the outgoing header contains **both** that and the context-management beta (proving union, not replace).

- [ ] **Step 1: Write the failing tests**

Add to `test/messages_test.exs`:

```elixir
describe "beta-header merge for %Request{}" do
  test "create/2 merges a request's declared betas into anthropic-beta",
       %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      assert beta_header =~ "token-counting-2024-11-01"
      assert beta_header =~ "context-management-2025-06-27"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-4-8",
          "stop_reason" => "end_turn",
          "stop_sequence" => nil,
          "content" => [%{"type" => "text", "text" => "ok"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      )
    end)

    request =
      Request.new("claude-opus-4-8")
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(16)
      |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

    assert {:ok, _response} = Claudio.Messages.create(client, request)
  end

  test "count_tokens/2 merges a request's declared betas",
       %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
      [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      assert beta_header =~ "context-management-2025-06-27"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"input_tokens" => 5}))
    end)

    request =
      Request.new("claude-opus-4-8")
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(16)
      |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

    assert {:ok, %{"input_tokens" => 5}} = Claudio.Messages.count_tokens(client, request)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/messages_test.exs`
Expected: FAIL — the `anthropic-beta` header lacks `context-management-2025-06-27` (today it's only the client's `token-counting` beta), so the in-callback assert fails.

- [ ] **Step 3: Merge betas in `create/2`**

Replace the `%Request{}` clause of `create/2`:

```elixir
  def create(client, %Request{} = request) do
    client = Claudio.Client.with_betas(client, Request.required_betas(request))
    create(client, Request.to_map(request))
  end
```

- [ ] **Step 4: Merge betas in `count_tokens/2`**

Replace the `%Request{}` clause of `count_tokens/2`:

```elixir
  def count_tokens(client, %Request{} = request) do
    client = Claudio.Client.with_betas(client, Request.required_betas(request))

    payload =
      request
      |> Request.to_map()
      |> Map.delete("stream")
      |> Map.delete("max_tokens")

    count_tokens(client, payload)
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/messages_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/messages.ex test/messages_test.exs
git commit -m "feat(messages): merge per-request betas in create/2 and count_tokens/2"
```

---

### Task 5: `Batches.create/2` accepts `%Request{}` params and merges betas

**Files:**
- Modify: `lib/claudio/batches.ex` (`alias` block top of module; `create/2` ~157-170; private helpers in the `# Private functions` section)
- Test: Create `test/batches_test.exs`

**Interfaces:**
- Consumes: `Request.required_betas/1` (Task 1), `Request.to_map/1`, `Claudio.Client.with_betas/2` (Task 3)
- Produces: `Batches.create/2` accepts items whose `:params`/`"params"` is a `%Request{}`, serializes them, and unions their betas onto the batch POST.

- [ ] **Step 1: Create the test file with failing tests**

Create `test/batches_test.exs`:

```elixir
defmodule Claudio.BatchesTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01", beta: ["token-counting-2024-11-01"]},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  test "create/2 merges betas from a %Request{} param and serializes it",
       %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages/batches", fn conn ->
      [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      assert beta_header =~ "context-management-2025-06-27"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      [item] = decoded["requests"]

      assert item["params"]["context_management"] ==
               %{"edits" => [%{"type" => "clear_tool_uses_20250919"}]}

      refute Map.has_key?(item["params"], "betas")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "batch_1",
          "type" => "message_batch",
          "processing_status" => "in_progress"
        })
      )
    end)

    req =
      Request.new("claude-opus-4-8")
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(16)
      |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

    requests = [%{custom_id: "r1", params: req}]

    assert {:ok, %{"id" => "batch_1"}} = Claudio.Batches.create(client, requests)
  end

  test "create/2 leaves a raw-map batch unchanged", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages/batches", fn conn ->
      [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      assert beta_header == "token-counting-2024-11-01"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "batch_2",
          "type" => "message_batch",
          "processing_status" => "in_progress"
        })
      )
    end)

    requests = [
      %{
        "custom_id" => "r1",
        "params" => %{
          "model" => "claude-3-5-sonnet-20241022",
          "max_tokens" => 16,
          "messages" => [%{"role" => "user", "content" => "hi"}]
        }
      }
    ]

    assert {:ok, %{"id" => "batch_2"}} = Claudio.Batches.create(client, requests)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/batches_test.exs`
Expected: FAIL — the first test's `anthropic-beta` header lacks `context-management-2025-06-27` (and a `%Request{}` struct passed as `params` would serialize incorrectly).

- [ ] **Step 3: Add the `Request` alias**

At the top of `lib/claudio/batches.ex`, alongside the existing `alias Claudio.APIError`, add:

```elixir
  alias Claudio.APIError
  alias Claudio.Messages.Request
```

- [ ] **Step 4: Rewrite `create/2` to prepare items and merge betas**

Replace `create/2`:

```elixir
  def create(client, requests) when is_list(requests) do
    {prepared, beta_lists} =
      requests
      |> Enum.map(&prepare_item/1)
      |> Enum.unzip()

    betas = beta_lists |> List.flatten() |> Enum.uniq()
    client = Claudio.Client.with_betas(client, betas)
    payload = %{"requests" => prepared}

    case Req.post(client, url: "messages/batches", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
```

- [ ] **Step 5: Add the `prepare_item/1` helpers**

In the `# Private functions` section (e.g. just above `defp build_query_params`), add:

```elixir
  defp prepare_item(%{params: %Request{} = req} = item),
    do: {%{item | params: Request.to_map(req)}, Request.required_betas(req)}

  defp prepare_item(%{"params" => %Request{} = req} = item),
    do: {Map.put(item, "params", Request.to_map(req)), Request.required_betas(req)}

  defp prepare_item(item), do: {item, []}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/batches_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/claudio/batches.ex test/batches_test.exs
git commit -m "feat(batches): accept %Request{} params and merge per-request betas"
```

---

### Task 6: Live integration test — positive + negative control

**Files:**
- Modify: `test/integration/messages_integration_test.exs` (add a `describe`)

**Interfaces:**
- Consumes: the full stack (Tasks 1-4). `IntegrationHelper.create_client/0` (no beta), `test_model/0`.

This test pins the dated beta string against the real API and proves the beta is load-bearing. It inherits the file's `setup_all` skip-if-no-key behavior (existing repo convention). An API key is present in this environment, so it runs.

- [ ] **Step 1: Add the test**

Add to `test/integration/messages_integration_test.exs` (inside the module, after the existing `describe "create/2"` block):

```elixir
  describe "per-feature beta headers (S2)" do
    test "set_context_management auto-attaches the beta (no client beta needed)",
         %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Say hi in one word")
        |> Request.set_max_tokens(32)
        |> Request.set_context_management(%{
          "edits" => [%{"type" => "clear_tool_uses_20250919"}]
        })

      # create_client/0 carries NO beta list; a 200 proves S2 supplied
      # `context-management-2025-06-27`.
      assert {:ok, %Response{}} = Messages.create(client, request)
    end

    test "the same request without the beta is rejected (negative control)",
         %{client: client} do
      raw = %{
        "model" => test_model(),
        "max_tokens" => 32,
        "messages" => [%{"role" => "user", "content" => "Say hi in one word"}],
        "context_management" => %{"edits" => [%{"type" => "clear_tool_uses_20250919"}]}
      }

      assert {:error, %Claudio.APIError{status_code: 400}} = Messages.create(client, raw)
    end
  end
```

- [ ] **Step 2: Run the integration test**

Run: `mix test --include integration test/integration/messages_integration_test.exs`
Expected: PASS — positive returns `{:ok, %Response{}}`; negative returns `{:error, %Claudio.APIError{status_code: 400}}`.

**Verification notes (resolve at execution time if it fails):**
- If the **positive** test `400`s with an error about the *model* not supporting context management (not about the beta), `test_model/0` doesn't support context editing — pin this test to a context-editing-capable model by using the literal `"claude-opus-4-8"` instead of `test_model()` in the positive test only.
- If the API rejects `clear_tool_uses_20250919` because no `tools` are present, add a trivial tool and a tool-use/tool-result turn to the positive request. (A no-op clear should be accepted; only add this if observed.)
- The negative control must fail with `status_code: 400` specifically. If it returns a different status, inspect the error and adjust the assertion to the real "missing beta" status the API returns.

- [ ] **Step 3: Commit**

```bash
git add test/integration/messages_integration_test.exs
git commit -m "test(integration): pin context-management beta with positive + negative control"
```

---

## Final verification

- [ ] Run the full default suite: `mix test` → all green (integration excluded).
- [ ] Run formatting check: `mix format --check-formatted`.
- [ ] Run the live test once: `mix test --include integration test/integration/messages_integration_test.exs` → green.

## Notes

- **Integration test convention (resolved):** "fail-loud" — per S1's convention (commit `5168a62`, "assert … instead of silently skipping") — means the test asserts its preconditions and cannot pass **vacuously**, NOT that it fails when no API key is present. S2's integration test satisfies this: the positive asserts `{:ok, %Response{}}` and the negative control asserts `{:error, %APIError{status_code: 400}}`, so a pass requires the beta to have been attached and required. It also follows the repo-standard `setup_all` skip-if-no-key gate (identical to S1's own tests in this module). No `IntegrationHelper` change is needed; the spec's earlier "fail when key absent" wording was inaccurate and has been corrected.
- **`Req.Request.get_header/2` / `put_header/3`** are the Req public API for reading/writing request headers; `with_betas/2` relies on them.
