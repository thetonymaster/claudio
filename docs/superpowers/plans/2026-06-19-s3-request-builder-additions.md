# S3 — Request-builder additions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three GA request-builder features to `Claudio.Messages.Request`: (1) **structured outputs** (`output_config.format`), (2) **strict / eager-input-streaming tool flags**, and (3) **message-level + top-level prompt caching** (`cache_control`).

**Architecture:** All changes are confined to `lib/claudio/messages/request.ex`. Two new struct fields (`output_config`, `cache_control`) are emitted by `to_map/1` as body fields. The strict/eager flags and message-block `cache_control` ride **inside** the tool/message maps that `add_tool/2` and `add_message/3` already pass through unchanged — the new helpers are thin wrappers. **No `anthropic-beta` header is involved** for any of these features (all GA), so unlike S2's `set_context_management/2`, none of the new setters call `add_beta/2`.

**Tech Stack:** Elixir, ExUnit, Bypass (none needed here — these are pure builder functions), live integration tests against the real API. API shapes verified against the bundled `claude-api` skill (2026-06): structured outputs and message-level caching are GA with no beta header; fine-grained tool streaming is a plain `eager_input_streaming: true` tool field (not a beta).

## Global Constraints

- **Additive only — no breaking changes.** Both new struct fields default to `nil`; `maybe_put` omits `nil`, so any request that doesn't use S3 features serializes byte-identically to today.
- **No betas.** None of structured outputs, `strict`, `eager_input_streaming`, or `cache_control` requires an `anthropic-beta` header. Do **not** call `add_beta/2` anywhere in S3. A unit test guards that `to_map/1` never emits `betas` (it already doesn't) and that S3 fields don't add betas.
- **Do NOT refactor the existing cache helpers.** `set_system_with_cache/2` and `add_tool_with_cache/2` have an inline `cache_control` `case` and **no direct test coverage**. Leave them untouched (Chesterton's Fence) — the new private `cache_control_map/1` serves only the two *new* caching functions. Deduping the pre-existing helpers is an optional later cleanup, out of scope here.
- **ttl values are passed through, not validated.** Mirror the existing helpers: `ttl: "5m"` / `"1h"` is the documented set, but the builder does not reject other strings (consistent with `set_system_with_cache/2`).
- **The builder does not enforce API-side constraints** (max 4 `cache_control` breakpoints; structured-outputs ⊕ citations incompatibility; `additionalProperties: false` + `required` for strict schemas). These are the caller's responsibility — document them in `@doc`, do not validate.
- **`set_output_format/2` merges** the `"format"` key into any existing `output_config` (so a prior `set_output_config(%{"effort" => ...})` survives). `set_output_config/2` is the raw replace-the-whole-map setter (mirrors `set_metadata/2`).
- **Git:** add files individually (never `git add .`); conventional-commit messages; **no AI attribution / Co-Authored-By lines**.
- **Tests:** unit tests are pure (`async: true`, no Bypass). Live tests are `@moduletag :integration`, excluded by default, run with `mix test --include integration`.

---

### Task 1: Structured outputs — `output_config` field, `set_output_config/2`, `set_output_format/2`

**Files:**
- Modify: `lib/claudio/messages/request.ex` (`@type t` ~22-41; `defstruct` ~43-62; new functions after `required_betas/1` ~553; `to_map/1` ~559-579)
- Test: `test/request_test.exs`

**Interfaces:**
- Produces:
  - struct field `output_config: map() | nil`, default `nil`
  - `set_output_config(t(), map()) :: t()` — raw replace
  - `set_output_format(t(), map()) :: t()` — wraps a JSON schema into `%{"format" => %{"type" => "json_schema", "schema" => schema}}`, merged into existing `output_config`
  - `to_map/1` emits `"output_config"` when set

- [ ] **Step 1: Write the failing tests**

Add to `test/request_test.exs` (after the `set_context_management/2` describe, before `to_map/1`):

```elixir
describe "set_output_config/2 and set_output_format/2" do
  test "set_output_format wraps a JSON schema as a json_schema format" do
    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"],
      "additionalProperties" => false
    }

    request =
      Request.new("claude-sonnet-4-6")
      |> Request.set_output_format(schema)

    map = Request.to_map(request)

    assert map["output_config"] == %{
             "format" => %{"type" => "json_schema", "schema" => schema}
           }
  end

  test "set_output_format preserves other output_config keys (merge, not replace)" do
    schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

    request =
      Request.new("claude-sonnet-4-6")
      |> Request.set_output_config(%{"effort" => "high"})
      |> Request.set_output_format(schema)

    map = Request.to_map(request)

    assert map["output_config"]["effort"] == "high"
    assert map["output_config"]["format"]["type"] == "json_schema"
    assert map["output_config"]["format"]["schema"] == schema
  end

  test "set_output_config sets the raw map" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.set_output_config(%{"format" => %{"type" => "json_schema", "schema" => %{}}})

    assert Request.to_map(request)["output_config"] ==
             %{"format" => %{"type" => "json_schema", "schema" => %{}}}
  end

  test "to_map omits output_config when unset" do
    refute Map.has_key?(Request.to_map(Request.new("claude-sonnet-4-6")), "output_config")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs`
Expected: FAIL — `function Claudio.Messages.Request.set_output_config/2 is undefined` (and `set_output_format/2`).

- [ ] **Step 3: Add the struct field + typespec**

In `@type t`, change the tail so it reads:

```elixir
          service_tier: String.t() | nil,
          betas: [String.t()],
          output_config: map() | nil,
          cache_control: map() | nil
        }
```

(Both S3 fields are added now so Task 3/4 needs no second typespec edit.)

In `defstruct`, change the tail so it reads:

```elixir
    :service_tier,
    betas: [],
    output_config: nil,
    cache_control: nil
  ]
```

- [ ] **Step 4: Add the two functions**

Insert immediately after `required_betas/1` (before the `to_map/1` doc):

```elixir
  @doc """
  Sets the raw `output_config` map.

  `output_config` is the API container for output controls (`format`, and on
  supported models `effort` / `task_budget`). This replaces the whole map; for
  structured JSON output prefer `set_output_format/2`, which merges.

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.set_output_config(%{"effort" => "high"})
  """
  @spec set_output_config(t(), map()) :: t()
  def set_output_config(%__MODULE__{} = request, config) when is_map(config) do
    %{request | output_config: config}
  end

  @doc """
  Requests structured JSON output matching `schema` (a JSON Schema map).

  Sets `output_config.format` to `{type: "json_schema", schema: schema}`, merging
  into any existing `output_config` (so a prior `set_output_config/2` survives).
  GA — no beta header. The schema must use `"additionalProperties" => false` and
  list its `"required"` keys. Not compatible with document citations.

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.set_output_format(%{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"],
        "additionalProperties" => false
      })
  """
  @spec set_output_format(t(), map()) :: t()
  def set_output_format(%__MODULE__{output_config: existing} = request, schema)
      when is_map(schema) do
    format = %{"type" => "json_schema", "schema" => schema}
    %{request | output_config: Map.put(existing || %{}, "format", format)}
  end
```

- [ ] **Step 5: Emit `output_config` in `to_map/1`**

In `to_map/1`, add after the `service_tier` line:

```elixir
    |> maybe_put("service_tier", request.service_tier)
    |> maybe_put("output_config", request.output_config)
    |> maybe_put("cache_control", request.cache_control)
```

(Adding both `maybe_put` lines now — `cache_control` stays `nil` until Task 4, so it's inert.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/request_test.exs`
Expected: PASS (all, including the existing tests).

- [ ] **Step 7: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(request): add structured outputs (output_config.format) via set_output_config/2 + set_output_format/2"
```

---

### Task 2: Tool flags — `add_strict_tool/2`, `add_tool_with_eager_streaming/2`

**Files:**
- Modify: `lib/claudio/messages/request.ex` (new functions in the S3 block)
- Test: `test/request_test.exs`

**Interfaces:**
- Consumes: `add_tool/2`
- Produces:
  - `add_strict_tool(t(), map()) :: t()` — appends a tool with `"strict" => true`
  - `add_tool_with_eager_streaming(t(), map()) :: t()` — appends a tool with `"eager_input_streaming" => true`

- [ ] **Step 1: Write the failing tests**

Add to `test/request_test.exs`:

```elixir
describe "add_strict_tool/2 and add_tool_with_eager_streaming/2" do
  @tool %{
    "name" => "get_weather",
    "description" => "Get weather",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"location" => %{"type" => "string"}},
      "required" => ["location"],
      "additionalProperties" => false
    }
  }

  test "add_strict_tool sets strict: true on the tool" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.add_strict_tool(@tool)

    [tool] = Request.to_map(request)["tools"]
    assert tool["strict"] == true
    assert tool["name"] == "get_weather"
  end

  test "add_tool_with_eager_streaming sets eager_input_streaming: true" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.add_tool_with_eager_streaming(@tool)

    [tool] = Request.to_map(request)["tools"]
    assert tool["eager_input_streaming"] == true
    assert tool["name"] == "get_weather"
  end

  test "both helpers append to existing tools" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.add_tool(@tool)
      |> Request.add_strict_tool(@tool)
      |> Request.add_tool_with_eager_streaming(@tool)

    assert length(Request.to_map(request)["tools"]) == 3
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs`
Expected: FAIL — `function Claudio.Messages.Request.add_strict_tool/2 is undefined`.

- [ ] **Step 3: Add the two functions** (in the S3 block, after the structured-output setters)

```elixir
  @doc """
  Adds a tool with strict schema validation enabled (`strict: true`).

  Guarantees the model's `tool_use.input` validates exactly against the schema.
  The schema must use `"additionalProperties" => false` and list `"required"`.
  GA — no beta header. (`strict` is a plain tool field; `add_tool/2` also passes
  it through if you set it yourself.)
  """
  @spec add_strict_tool(t(), map()) :: t()
  def add_strict_tool(%__MODULE__{} = request, tool) when is_map(tool) do
    add_tool(request, Map.put(tool, "strict", true))
  end

  @doc """
  Adds a tool with fine-grained ("eager") input streaming enabled.

  Sets `eager_input_streaming: true` so the tool's `input_json_delta` chunks
  stream as they are generated. GA — not a beta feature; use the regular
  streaming path (`enable_streaming/1`).
  """
  @spec add_tool_with_eager_streaming(t(), map()) :: t()
  def add_tool_with_eager_streaming(%__MODULE__{} = request, tool) when is_map(tool) do
    add_tool(request, Map.put(tool, "eager_input_streaming", true))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/request_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(request): add add_strict_tool/2 and add_tool_with_eager_streaming/2"
```

---

### Task 3: Message-level caching — `add_message_with_cache/4` + private `cache_control_map/1`

**Files:**
- Modify: `lib/claudio/messages/request.ex` (new function in the S3 block; new private helper near `normalize_content/1`)
- Test: `test/request_test.exs`

**Interfaces:**
- Consumes: `add_message/3`
- Produces:
  - `add_message_with_cache(t(), role(), String.t(), keyword()) :: t()` — appends a text turn whose single content block carries `cache_control`
  - private `cache_control_map(ttl) :: map()`

- [ ] **Step 1: Write the failing tests**

Add to `test/request_test.exs`:

```elixir
describe "add_message_with_cache/4" do
  test "adds a text block with default ephemeral cache_control" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.add_message_with_cache(:user, "long context...")

    [message] = Request.to_map(request)["messages"]
    assert message["role"] == "user"

    assert message["content"] == [
             %{
               "type" => "text",
               "text" => "long context...",
               "cache_control" => %{"type" => "ephemeral"}
             }
           ]
  end

  test "honours an explicit ttl" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.add_message_with_cache(:assistant, "cached", ttl: "1h")

    [message] = Request.to_map(request)["messages"]

    assert message["content"] == [
             %{
               "type" => "text",
               "text" => "cached",
               "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
             }
           ]
  end

  test "appends after other messages" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.add_message(:user, "first")
      |> Request.add_message_with_cache(:user, "second")

    assert length(Request.to_map(request)["messages"]) == 2
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs`
Expected: FAIL — `function Claudio.Messages.Request.add_message_with_cache/4 is undefined`.

- [ ] **Step 3: Add the function** (in the S3 block, after the tool helpers)

```elixir
  @doc """
  Adds a text message whose content block carries a `cache_control` breakpoint.

  Use for the "growing conversation prefix" caching pattern — mark the last
  stable turn so the prefix up to it is cached. GA — no beta header. Up to 4
  `cache_control` breakpoints are allowed per request (not enforced here).

  ## Options

  - `:ttl` — cache duration, `"5m"` (default) or `"1h"`

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.add_message_with_cache(:user, "Large shared context...", ttl: "1h")
      |> Request.add_message(:user, "The actual question")
  """
  @spec add_message_with_cache(t(), role(), String.t(), keyword()) :: t()
  def add_message_with_cache(%__MODULE__{} = request, role, text, opts \\ [])
      when role in [:user, :assistant] and is_binary(text) do
    content = [
      %{
        "type" => "text",
        "text" => text,
        "cache_control" => cache_control_map(Keyword.get(opts, :ttl))
      }
    ]

    add_message(request, role, content)
  end
```

- [ ] **Step 4: Add the private helper** (next to `normalize_content/1` at the bottom)

```elixir
  defp cache_control_map(nil), do: %{"type" => "ephemeral"}
  defp cache_control_map(ttl), do: %{"type" => "ephemeral", "ttl" => ttl}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/request_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(request): add add_message_with_cache/4 for message-level prompt caching"
```

---

### Task 4: Top-level caching — `set_cache_control/2`

**Files:**
- Modify: `lib/claudio/messages/request.ex` (new function in the S3 block; `cache_control` field + `to_map` line already added in Task 1)
- Test: `test/request_test.exs`

**Interfaces:**
- Consumes: `cache_control_map/1` (Task 3)
- Produces:
  - `set_cache_control(t(), keyword()) :: t()` — sets the top-level `cache_control` (auto-places on the last cacheable block, server-side)
  - `to_map/1` emits `"cache_control"` when set (line added in Task 1)

- [ ] **Step 1: Write the failing tests**

Add to `test/request_test.exs`:

```elixir
describe "set_cache_control/2" do
  test "sets top-level cache_control with default ttl" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.set_cache_control()

    assert Request.to_map(request)["cache_control"] == %{"type" => "ephemeral"}
  end

  test "honours an explicit ttl" do
    request =
      Request.new("claude-sonnet-4-6")
      |> Request.set_cache_control(ttl: "1h")

    assert Request.to_map(request)["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
  end

  test "to_map omits cache_control when unset" do
    refute Map.has_key?(Request.to_map(Request.new("claude-sonnet-4-6")), "cache_control")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs`
Expected: FAIL — `function Claudio.Messages.Request.set_cache_control/2 is undefined`.

- [ ] **Step 3: Add the function** (in the S3 block, after `add_message_with_cache/4`)

```elixir
  @doc """
  Sets a top-level `cache_control` breakpoint, auto-placed on the last cacheable
  block of the request (server-side). The simplest way to cache the request
  prefix when you don't need per-block placement. GA — no beta header.

  ## Options

  - `:ttl` — cache duration, `"5m"` (default) or `"1h"`

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.set_system("Large shared context...")
      |> Request.set_cache_control(ttl: "1h")
  """
  @spec set_cache_control(t(), keyword()) :: t()
  def set_cache_control(%__MODULE__{} = request, opts \\ []) do
    %{request | cache_control: cache_control_map(Keyword.get(opts, :ttl))}
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/request_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(request): add set_cache_control/2 for top-level prompt caching"
```

---

### Task 5: Live integration tests — structured outputs + message-level caching

**Files:**
- Modify: `test/integration/messages_integration_test.exs` (add a `describe`)

**Interfaces:**
- Consumes: the full stack. `IntegrationHelper.create_client/0` (no beta), `test_model/0`.

Two fail-loud positive controls (per the S1/S2 convention: assert real outcomes so the test cannot pass vacuously).

- [ ] **Step 1: Add the tests**

Add to `test/integration/messages_integration_test.exs` (inside the module, after the `extended thinking round-trip` describe):

```elixir
  describe "request-builder additions (S3)" do
    # Structured outputs are GA on Sonnet 4.6 / Opus 4.8 / Haiku 4.5 — NOT on the
    # default test_model (Sonnet 4.5). Pin to a supporting model.
    @structured_model "claude-sonnet-4-6"

    test "structured outputs returns schema-valid JSON", %{client: client} do
      schema = %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string"},
          "country" => %{"type" => "string"}
        },
        "required" => ["city", "country"],
        "additionalProperties" => false
      }

      request =
        Request.new(@structured_model)
        |> Request.add_message(:user, "The capital of France, as JSON.")
        |> Request.set_max_tokens(256)
        |> Request.set_output_format(schema)

      assert {:ok, %Response{} = response} = Messages.create(client, request)

      # output_config.format guarantees the first text block is valid JSON.
      decoded = Jason.decode!(Response.get_text(response))
      assert Map.has_key?(decoded, "city")
      assert Map.has_key?(decoded, "country")
    end

    test "message-level cache_control is accepted and caches the prefix",
         %{client: client} do
      # A prefix long enough to exceed the model's min cacheable size (~1024
      # tokens on Sonnet 4.5) so cache_creation_input_tokens is populated.
      long_context = String.duplicate("The quick brown fox jumps over the lazy dog. ", 400)

      request =
        Request.new(test_model())
        |> Request.add_message_with_cache(:user, long_context, ttl: "5m")
        |> Request.add_message(:user, "Reply with the single word: ok")
        |> Request.set_max_tokens(16)

      assert {:ok, %Response{usage: usage}} = Messages.create(client, request)

      # A 200 proves cache_control was accepted; a non-nil creation count proves
      # the prefix was actually cached (not silently below the minimum).
      assert usage.cache_creation_input_tokens > 0
    end
  end
```

- [ ] **Step 2: Run the integration tests**

Run: `mix test --include integration test/integration/messages_integration_test.exs`
Expected: PASS — structured output decodes to a map with `city`/`country`; cache test returns `{:ok, ...}` with `cache_creation_input_tokens > 0`.

**Verification notes (resolve at execution time if it fails):**
- If the structured-outputs test `400`s about the *model* not supporting structured outputs, switch `@structured_model` to `"claude-opus-4-8"`.
- If the structured-outputs test `400`s about the *schema*, ensure `additionalProperties` is `false` and every property is listed in `required`.
- If `cache_creation_input_tokens` is `0` (prefix below the model's cacheable minimum), enlarge `long_context` (raise the `400` repeat count). If the API already had the prefix cached from a prior run, the count may instead surface on `cache_read_input_tokens` — relax the assertion to `usage.cache_creation_input_tokens > 0 or usage.cache_read_input_tokens > 0`.

- [ ] **Step 3: Commit**

```bash
git add test/integration/messages_integration_test.exs
git commit -m "test(integration): live structured-outputs + message-level caching controls (S3)"
```

---

### Task 6: Docs — CLAUDE.md + CHANGELOG

**Files:**
- Modify: `CLAUDE.md` (Request Builder bullet list), `CHANGELOG.md`

- [ ] **Step 1: Update the Request Builder section of `CLAUDE.md`**

Add bullets under the request-builder feature list noting structured outputs (`set_output_format/2` / `set_output_config/2`), strict / eager-streaming tool helpers, and message-level + top-level caching (`add_message_with_cache/4` / `set_cache_control/2`), each "GA, no beta header".

- [ ] **Step 2: Add a CHANGELOG entry** (Unreleased / next version) summarizing the S3 additions.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: document S3 request-builder additions"
```

---

## Final verification

- [ ] Run the full default suite: `mix test` → all green (integration excluded).
- [ ] Run formatting check: `mix format --check-formatted`.
- [ ] Run the live tests once: `mix test --include integration test/integration/messages_integration_test.exs` → green.
- [ ] Open a PR from `s3-request-builder-additions` → `main` (do NOT auto-merge).

## Notes

- **Why no betas:** verified against the bundled `claude-api` skill — structured outputs (`output_config.format`) and message-level/top-level `cache_control` are GA; fine-grained tool streaming is a plain `eager_input_streaming: true` tool field, explicitly *not* a beta. This is the key contrast with S2, whose `set_context_management/2` had to declare `context-management-2025-06-27`. So `required_betas/1` stays `[]` for any request that only uses S3 features.
- **`strict` / `eager_input_streaming` already worked via raw maps** (`add_tool/2` passes arbitrary tool maps through). The S3 helpers add discoverability + ergonomics, matching the `add_tool_with_cache/3` precedent.
- **Existing cache helpers untouched.** `set_system_with_cache/2` and `add_tool_with_cache/2` keep their inline `cache_control` `case`. They have no direct tests, so refactoring them onto `cache_control_map/1` is deferred (would add risk for no functional gain).
