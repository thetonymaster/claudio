# S4 — Models API module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `Claudio.Models` — a thin wrapper over the GA Models API: `list/2` (`GET /v1/models`, paginated) and `get/2` (`GET /v1/models/{id}`). No new module exists today; the roadmap calls this a ~1-file freebie.

**Architecture:** New module `lib/claudio/models.ex`, structurally identical to `Claudio.Files` (the closest analog: a thin resource API). Uses `Req.get/2` with `build_query_params/1` for pagination, returns the raw decoded body `{:ok, map()}`, and maps non-200 to `Claudio.APIError` via `APIError.from_response/2`. **GA — no beta header**, so unlike `Claudio.Files` there is no beta-gating section.

**Tech Stack:** Elixir, ExUnit, Bypass (unit HTTP mocking), live integration tests. API shape verified against the bundled `claude-api` skill: `client.models.list()` (auto-paginates) + `client.models.retrieve(id)`; each model object has `id`, `display_name`, `created_at`, `type: "model"`, and (since Mar 2026) `max_input_tokens` / `max_tokens` / `capabilities`. No `context_window` field.

## Global Constraints

- **No beta header.** Models API is GA. The client built by `Claudio.Client.new/2` (no beta) must work as-is.
- **Mirror `Claudio.Files` exactly** — same `case Req.{verb} … do` shape, same `APIError.from_response/2` mapping, same `build_query_params/1` + `maybe_add_param/3` pagination helpers, same `@spec`/`@doc` style. Return the raw body (`{:ok, body}`), not a typed struct — consistent with `Files`/`Batches`.
- **Endpoints:** `GET /v1/models` (list, params `limit` / `before_id` / `after_id`) and `GET /v1/models/{model_id}` (retrieve). The client base URL already includes `/v1/` (Bypass tests pass a base URL), so use relative `"models"` / `"models/#{id}"` exactly like `Files` uses `"files"`.
- **Git:** add files individually (never `git add .`); conventional commits; **no AI attribution**.
- **Tests:** unit tests use Bypass with `async: true`; the live test is `@moduletag :integration`, excluded by default.

---

### Task 1: `Claudio.Models` module + unit tests

**Files:**
- Create: `lib/claudio/models.ex`
- Create: `test/models_test.exs`

**Interfaces:**
- `Claudio.Models.list(Req.Request.t(), keyword()) :: {:ok, map()} | {:error, APIError.t() | term()}`
- `Claudio.Models.get(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t() | term()}`

- [ ] **Step 1: Write the failing tests** — create `test/models_test.exs`:

```elixir
defmodule Claudio.ModelsTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01"},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  describe "list/2" do
    test "returns the model list", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["fake-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{
                "id" => "claude-opus-4-8",
                "type" => "model",
                "display_name" => "Claude Opus 4.8",
                "created_at" => "2026-01-01T00:00:00Z"
              }
            ],
            "first_id" => "claude-opus-4-8",
            "last_id" => "claude-opus-4-8",
            "has_more" => false
          })
        )
      end)

      assert {:ok, %{"data" => [%{"id" => "claude-opus-4-8"}]}} =
               Claudio.Models.list(client)
    end

    test "passes :limit, :before_id, and :after_id as query params", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["limit"] == "50"
        assert params["before_id"] == "claude-y"
        assert params["after_id"] == "claude-x"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [], "has_more" => false}))
      end)

      assert {:ok, _} =
               Claudio.Models.list(client, limit: 50, before_id: "claude-y", after_id: "claude-x")
    end

    test "maps non-200 responses to Claudio.APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          401,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
          })
        )
      end)

      assert {:error, %Claudio.APIError{status_code: 401, type: :authentication_error}} =
               Claudio.Models.list(client)
    end
  end

  describe "get/2" do
    test "returns a single model", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models/claude-opus-4-8", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "claude-opus-4-8",
            "type" => "model",
            "display_name" => "Claude Opus 4.8",
            "created_at" => "2026-01-01T00:00:00Z"
          })
        )
      end)

      assert {:ok, %{"id" => "claude-opus-4-8", "type" => "model"}} =
               Claudio.Models.get(client, "claude-opus-4-8")
    end

    test "maps a 404 to Claudio.APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models/nope", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{"type" => "not_found_error", "message" => "model not found"}
          })
        )
      end)

      assert {:error, %Claudio.APIError{status_code: 404, type: :not_found_error}} =
               Claudio.Models.get(client, "nope")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/models_test.exs`
Expected: FAIL — `Claudio.Models.list/2 is undefined` (module doesn't exist).

- [ ] **Step 3: Create `lib/claudio/models.ex`**

```elixir
defmodule Claudio.Models do
  @moduledoc """
  Anthropic Models API client.

  Discover available Claude models and their capabilities at runtime. GA — no
  beta header required.

  ## Example

      client = Claudio.Client.new(%{token: "sk-ant-...", version: "2023-06-01"})

      {:ok, %{"data" => models}} = Claudio.Models.list(client, limit: 20)
      {:ok, model} = Claudio.Models.get(client, "claude-opus-4-8")
  """

  alias Claudio.APIError

  @doc """
  Lists available models (most recently released first), paginated.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `opts` — Optional keyword list:
        * `:limit` — Number of models to return (default server-side: 20).
        * `:before_id` — Cursor for the previous page (model id).
        * `:after_id` — Cursor for the next page (model id).

  ## Returns

    * `{:ok, %{"data" => [...], "first_id" => _, "last_id" => _, "has_more" => _}}`
      on success.
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec list(Req.Request.t(), keyword()) :: {:ok, map()} | {:error, APIError.t() | term()}
  def list(client, opts \\ []) do
    query_params = build_query_params(opts)

    case Req.get(client, url: "models", params: query_params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves a single model by id or alias.

  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `model_id` — A model id or alias (e.g. `"claude-opus-4-8"`).

  ## Returns

    * `{:ok, %{"id" => _, "type" => "model", "display_name" => _, "created_at" => _}}`
      on success (may also include `max_input_tokens` / `max_tokens` / `capabilities`).
    * `{:error, %Claudio.APIError{}}` on a non-200 response.
    * `{:error, term()}` on a transport/Req error.
  """
  @spec get(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t() | term()}
  def get(client, model_id) when is_binary(model_id) do
    case Req.get(client, url: "models/#{model_id}") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_query_params(opts) do
    []
    |> maybe_add_param(:limit, Keyword.get(opts, :limit))
    |> maybe_add_param(:before_id, Keyword.get(opts, :before_id))
    |> maybe_add_param(:after_id, Keyword.get(opts, :after_id))
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/models_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/models.ex test/models_test.exs
git commit -m "feat(models): add Claudio.Models with list/2 and get/2 (Models API)"
```

---

### Task 2: ex_doc group + CLAUDE.md docs

**Files:**
- Modify: `mix.exs` (`groups_for_modules`)
- Modify: `CLAUDE.md` (module org + a short Models API section)

- [ ] **Step 1: Add `Claudio.Models` to a `groups_for_modules` entry in `mix.exs`** (mirror how `Claudio.Files` / `Claudio.Batches` are grouped — pick the closest existing group, e.g. an "API" / top-level group, or add a `"Models API"` group for parity with the others).

- [ ] **Step 2: Document in `CLAUDE.md`** — add `Claudio.Models` (`list/2`, `get/2`, GA no beta) to the module-organization tree and a one-paragraph section next to the Files/Batches sections.

- [ ] **Step 3: Verify docs build** (if the repo builds docs): `mix docs` (optional; skip if `ex_doc` isn't a dev dep / fails offline). At minimum `mix compile --warnings-as-errors` to ensure the module compiles cleanly.

- [ ] **Step 4: Commit**

```bash
git add mix.exs CLAUDE.md
git commit -m "docs(models): group Claudio.Models in ex_doc and document it"
```

---

### Task 3: Live integration test

**Files:**
- Create: `test/integration/models_integration_test.exs`

This is **fail-loud** (per S1–S3 convention): assert real shape so it can't pass vacuously. `list` then `get` the first returned id (avoids hardcoding a model that might be retired).

- [ ] **Step 1: Create the test**

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ModelsIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Claudio.Models

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  describe "list/2 + get/2 (live)" do
    test "lists models and retrieves one by id", %{client: client} do
      assert {:ok, %{"data" => models}} = Models.list(client, limit: 5)
      assert is_list(models)
      assert length(models) > 0

      first_id = hd(models)["id"]
      assert is_binary(first_id)

      assert {:ok, model} = Models.get(client, first_id)
      assert model["id"] == first_id
      assert model["type"] == "model"
    end

    test "a bogus model id returns a 404 APIError", %{client: client} do
      assert {:error, %Claudio.APIError{status_code: 404}} =
               Models.get(client, "claude-does-not-exist-00000000")
    end
  end
end
```

- [ ] **Step 2: Run the integration test**

Run: `mix test --include integration test/integration/models_integration_test.exs`
Expected: PASS — list returns ≥1 model; get echoes the id; bogus id → 404.

**Verification note:** if the bogus-id call returns a different status (e.g. 400), relax to `status_code in [400, 404]` and note the real status.

- [ ] **Step 3: Commit**

```bash
git add test/integration/models_integration_test.exs
git commit -m "test(integration): live Claudio.Models list + get controls (S4)"
```

---

## Final verification

- [ ] `mix test` → all green (integration excluded).
- [ ] `mix format --check-formatted`.
- [ ] `mix test --include integration test/integration/models_integration_test.exs` → green.
- [ ] Open a PR `s4-models-api` → `main` (do NOT auto-merge).

## Notes

- **Why raw maps, not structs:** matches `Claudio.Files` / `Claudio.Batches`, which return the decoded body. A typed `Model` struct would be a larger, inconsistent change — out of scope (the roadmap scoped S4 as a ~1-file freebie). Capability querying can read `body["capabilities"]` directly.
- **No `Claudio` top-level convenience** (e.g. `Claudio.list_models/2`) added — the library exposes resource modules directly (`Claudio.Files`, `Claudio.Batches`), so `Claudio.Models` follows suit.
