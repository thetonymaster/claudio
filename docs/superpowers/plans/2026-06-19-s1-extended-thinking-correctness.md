# S1 — Extended-thinking round-trip correctness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Claudio from losing `signature` / `redacted_thinking` / streamed citation data so a multi-turn extended-thinking + tool-use conversation can be replayed without a 400.

**Architecture:** Additive changes to two modules — `response.ex` (non-streaming parse + a new round-trip helper) and `stream.ex` (two new `apply_delta` clauses). No public function changes; new fields and one new function only.

**Tech Stack:** Elixir ~> 1.15, ExUnit, Poison (JSON), Req (HTTP). Design doc: `docs/superpowers/specs/2026-06-19-s1-extended-thinking-correctness-design.md`.

## Global Constraints

- **Additive only** — no breaking changes to existing public functions or response shapes.
- **Dual-key clause pattern** — every content-block/delta clause is written twice: once matching atom keys (`%{type: "..."}`), once matching string keys (`%{"type" => "..."}`). Follow the existing style in `response.ex`/`stream.ex`.
- **No AI attribution in commits** (project rule). Add files individually; never `git add .`.
- **Integration tests** are tagged `@moduletag :integration` and excluded by default (`test/test_helper.exs` runs `ExUnit.start(exclude: [:integration])`).
- **Beads:** this plan implements `claudio-hms` (epic `claudio-8rv`). Branch: `s1-extended-thinking-correctness`.
- Citation *typing* (typed structs, request toggle) is **out of scope** — deferred to S5 (`claudio-0vx`). S1 only preserves/accumulates raw citation data.

---

### Task 1: Preserve `signature` on parsed thinking blocks

**Files:**
- Modify: `lib/claudio/messages/response.ex` (type at `:28-31`; thinking clauses at `:155-161`)
- Test: `test/response_test.exs`

**Interfaces:**
- Produces: parsed thinking block shape `%{type: :thinking, thinking: String.t(), signature: String.t() | nil}` (consumed by Task 3 and Task 6).

- [ ] **Step 1: Write the failing tests**

Add to `test/response_test.exs` inside the module (new `describe`):

```elixir
describe "from_map/1 thinking blocks" do
  test "preserves signature on thinking blocks (string keys)" do
    data = %{
      "content" => [%{"type" => "thinking", "thinking" => "hmm", "signature" => "sig_abc"}],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    response = Response.from_map(data)

    assert [%{type: :thinking, thinking: "hmm", signature: "sig_abc"}] = response.content
  end

  test "thinking signature is nil when absent" do
    data = %{
      "content" => [%{"type" => "thinking", "thinking" => "hmm"}],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    response = Response.from_map(data)

    assert [%{type: :thinking, thinking: "hmm", signature: nil}] = response.content
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/response_test.exs`
Expected: the two new tests FAIL — the parsed map has no `:signature` key, so the match fails.

- [ ] **Step 3: Add `signature` to the thinking parse clauses and type**

In `lib/claudio/messages/response.ex`, replace the two thinking clauses (currently `:155-161`):

```elixir
defp parse_content_block(%{type: "thinking"} = block) do
  %{type: :thinking, thinking: block[:thinking], signature: block[:signature]}
end

defp parse_content_block(%{"type" => "thinking"} = block) do
  %{type: :thinking, thinking: block["thinking"], signature: block["signature"]}
end
```

And update the `thinking_block` type (currently `:28-31`):

```elixir
@type thinking_block :: %{
        type: :thinking,
        thinking: String.t(),
        signature: String.t() | nil
      }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/response_test.exs`
Expected: PASS (all tests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/response.ex test/response_test.exs
git commit -m "fix(response): preserve signature on parsed thinking blocks"
```

---

### Task 2: Parse `redacted_thinking` as a typed block

**Files:**
- Modify: `lib/claudio/messages/response.ex` (content_block union at `:15-21`; add type near `:28-31`; add clauses after the thinking clauses)
- Test: `test/response_test.exs`

**Interfaces:**
- Produces: parsed block shape `%{type: :redacted_thinking, data: String.t()}` (consumed by Task 3 and Task 6).

- [ ] **Step 1: Write the failing tests**

Add to `test/response_test.exs`:

```elixir
describe "from_map/1 redacted_thinking blocks" do
  test "parses redacted_thinking as a typed block (string keys)" do
    data = %{
      "content" => [%{"type" => "redacted_thinking", "data" => "enc_xyz"}],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    response = Response.from_map(data)

    assert [%{type: :redacted_thinking, data: "enc_xyz"}] = response.content
  end

  test "parses redacted_thinking as a typed block (atom keys)" do
    data = %{
      content: [%{type: "redacted_thinking", data: "enc_xyz"}],
      usage: %{input_tokens: 1, output_tokens: 1}
    }

    response = Response.from_map(data)

    assert [%{type: :redacted_thinking, data: "enc_xyz"}] = response.content
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/response_test.exs`
Expected: both new tests FAIL — `redacted_thinking` currently hits the `parse_content_block(block), do: block` fallthrough and returns the raw map (`%{"type" => "redacted_thinking", ...}` / `%{type: "redacted_thinking", ...}`), which does not match `%{type: :redacted_thinking, ...}`.

- [ ] **Step 3: Add the parse clauses, type, and union member**

In `lib/claudio/messages/response.ex`, add these two clauses immediately after the string-key thinking clause (after `:161`, before the `tool_use` clause):

```elixir
defp parse_content_block(%{type: "redacted_thinking"} = block) do
  %{type: :redacted_thinking, data: block[:data]}
end

defp parse_content_block(%{"type" => "redacted_thinking"} = block) do
  %{type: :redacted_thinking, data: block["data"]}
end
```

Add the type (near `:28-31`):

```elixir
@type redacted_thinking_block :: %{
        type: :redacted_thinking,
        data: String.t()
      }
```

Add it to the `content_block` union (currently `:15-21`):

```elixir
@type content_block ::
        text_block()
        | thinking_block()
        | redacted_thinking_block()
        | tool_use_block()
        | tool_result_block()
        | mcp_tool_use_block()
        | mcp_tool_result_block()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/response_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/response.ex test/response_test.exs
git commit -m "fix(response): parse redacted_thinking as a typed content block"
```

---

### Task 3: `Response.to_assistant_content/1` round-trip helper

**Files:**
- Modify: `lib/claudio/messages/response.ex` (new public function + private `block_to_api/1` clauses)
- Test: `test/response_test.exs`

**Interfaces:**
- Consumes: parsed block shapes from Tasks 1 & 2 (`:thinking` with `signature`, `:redacted_thinking` with `data`), plus existing `:text` and `:tool_use`.
- Produces: `to_assistant_content(t()) :: [map()]` — string-keyed, API-exact blocks (consumed by Task 6 and by library users for replay).

- [ ] **Step 1: Write the failing tests**

Add to `test/response_test.exs`. Make sure `alias Claudio.Messages.Response` is present (it is, at the top of the file):

```elixir
describe "to_assistant_content/1" do
  test "emits API-shaped string-keyed blocks preserving signature, data, tool_use" do
    response = %Response{
      content: [
        %{type: :text, text: "answer"},
        %{type: :thinking, thinking: "reasoning", signature: "sig_abc"},
        %{type: :redacted_thinking, data: "enc_xyz"},
        %{type: :tool_use, id: "toolu_1", name: "get_weather", input: %{"location" => "NYC"}}
      ]
    }

    assert Response.to_assistant_content(response) == [
             %{"type" => "text", "text" => "answer"},
             %{"type" => "thinking", "thinking" => "reasoning", "signature" => "sig_abc"},
             %{"type" => "redacted_thinking", "data" => "enc_xyz"},
             %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "get_weather",
               "input" => %{"location" => "NYC"}
             }
           ]
  end

  test "omits signature when nil" do
    response = %Response{content: [%{type: :thinking, thinking: "x", signature: nil}]}

    assert Response.to_assistant_content(response) == [%{"type" => "thinking", "thinking" => "x"}]
  end

  test "passes unknown block types through unchanged" do
    response = %Response{content: [%{type: :mcp_tool_use, id: "x", name: "n", server_name: "s", input: %{}}]}

    assert Response.to_assistant_content(response) ==
             [%{type: :mcp_tool_use, id: "x", name: "n", server_name: "s", input: %{}}]
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/response_test.exs`
Expected: the three new tests FAIL with `UndefinedFunctionError`/`function to_assistant_content/1 is undefined`.

- [ ] **Step 3: Implement the helper**

In `lib/claudio/messages/response.ex`, add the public function (place it with the other public helpers, e.g. after `get_mcp_tool_uses/2` near `:141`):

```elixir
@doc """
Converts the response content into API-shaped assistant content blocks for
replaying as the assistant turn in a follow-up request:

    request
    |> Request.add_message(:assistant, Response.to_assistant_content(response))

Emits string-keyed blocks that preserve `signature` (thinking) and `data`
(redacted_thinking) — both required by the API when continuing an
extended-thinking + tool-use conversation. Unknown block types are passed
through unchanged (coverage grows in later specs).
"""
@spec to_assistant_content(t()) :: [map()]
def to_assistant_content(%__MODULE__{content: content}) do
  Enum.map(content, &block_to_api/1)
end
```

And add the private clauses (place them near the `parse_content_block/1` clauses):

```elixir
defp block_to_api(%{type: :text, text: text}) do
  %{"type" => "text", "text" => text}
end

defp block_to_api(%{type: :thinking, thinking: thinking} = block) do
  base = %{"type" => "thinking", "thinking" => thinking}

  case block[:signature] do
    nil -> base
    signature -> Map.put(base, "signature", signature)
  end
end

defp block_to_api(%{type: :redacted_thinking, data: data}) do
  %{"type" => "redacted_thinking", "data" => data}
end

defp block_to_api(%{type: :tool_use, id: id, name: name, input: input}) do
  %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
end

defp block_to_api(block), do: block
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/response_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/response.ex test/response_test.exs
git commit -m "feat(response): add to_assistant_content/1 round-trip helper"
```

---

### Task 4: Streaming — preserve `signature_delta` (and guard redacted_thinking)

**Files:**
- Modify: `lib/claudio/messages/stream.ex` (`apply_delta/2` clauses, add before the catch-all at `:376`)
- Test: `test/messages/stream_test.exs`

**Interfaces:**
- Consumes: SSE events parsed by `parse_events/1`, accumulated by `build_final_message/1`.
- Produces: final streamed thinking block carries `"signature"`; `redacted_thinking` block survives streaming.

- [ ] **Step 1: Write the failing test (+ regression guard that passes immediately)**

Add to `test/messages/stream_test.exs` (note the existing alias `ClaudioStream`):

```elixir
describe "build_final_message/1 thinking" do
  test "preserves signature from signature_delta on the final thinking block" do
    sse = [
      ~s(event: content_block_start),
      ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}),
      "",
      ~s(event: content_block_delta),
      ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"reasoning"}}),
      "",
      ~s(event: content_block_delta),
      ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_abc"}}),
      "",
      ~s(event: content_block_stop),
      ~s(data: {"type":"content_block_stop","index":0}),
      "",
      ~s(event: message_stop),
      ~s(data: {"type":"message_stop"}),
      ""
    ]

    {:ok, message} =
      [Enum.join(sse, "\n") <> "\n"]
      |> ClaudioStream.parse_events()
      |> ClaudioStream.build_final_message()

    assert [%{"type" => "thinking", "thinking" => "reasoning", "signature" => "sig_abc"}] =
             message["content"]
  end

  test "redacted_thinking blocks survive streaming unchanged" do
    sse = [
      ~s(event: content_block_start),
      ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"enc_xyz"}}),
      "",
      ~s(event: content_block_stop),
      ~s(data: {"type":"content_block_stop","index":0}),
      "",
      ~s(event: message_stop),
      ~s(data: {"type":"message_stop"}),
      ""
    ]

    {:ok, message} =
      [Enum.join(sse, "\n") <> "\n"]
      |> ClaudioStream.parse_events()
      |> ClaudioStream.build_final_message()

    assert [%{"type" => "redacted_thinking", "data" => "enc_xyz"}] = message["content"]
  end
end
```

- [ ] **Step 2: Run the tests to verify the signature test fails**

Run: `mix test test/messages/stream_test.exs`
Expected: the `signature_delta` test FAILS — the final thinking block has no `"signature"` key (the delta hit the `apply_delta(block, _delta), do: block` catch-all). The `redacted_thinking survives streaming` test PASSES immediately (it guards existing behavior — `build_final_message/1` already keeps the `content_block_start` block, which carries `data`, and there are no deltas to drop).

- [ ] **Step 3: Add the `signature_delta` clauses**

In `lib/claudio/messages/stream.ex`, add immediately before the catch-all `defp apply_delta(block, _delta), do: block` (currently `:376`):

```elixir
defp apply_delta(block, %{"type" => "signature_delta", "signature" => signature}) do
  Map.put(block, "signature", signature)
end

defp apply_delta(block, %{type: "signature_delta", signature: signature}) do
  Map.put(block, "signature", signature)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/messages/stream_test.exs`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/stream.ex test/messages/stream_test.exs
git commit -m "fix(stream): preserve signature_delta on streamed thinking blocks"
```

---

### Task 5: Streaming — accumulate `citations_delta`

**Files:**
- Modify: `lib/claudio/messages/stream.ex` (`apply_delta/2` clauses, before the catch-all)
- Test: `test/messages/stream_test.exs`

**Interfaces:**
- Produces: streamed block accumulates raw citation objects under `"citations"` (typed parsing deferred to S5).

- [ ] **Step 1: Write the failing test**

Add to `test/messages/stream_test.exs`:

```elixir
describe "build_final_message/1 citations" do
  test "accumulates citations_delta onto the streamed block" do
    sse = [
      ~s(event: content_block_start),
      ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
      "",
      ~s(event: content_block_delta),
      ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Paris"}}),
      "",
      ~s(event: content_block_delta),
      ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"citations_delta","citation":{"type":"char_location","cited_text":"Paris is the capital","document_index":0}}}),
      "",
      ~s(event: content_block_stop),
      ~s(data: {"type":"content_block_stop","index":0}),
      "",
      ~s(event: message_stop),
      ~s(data: {"type":"message_stop"}),
      ""
    ]

    {:ok, message} =
      [Enum.join(sse, "\n") <> "\n"]
      |> ClaudioStream.parse_events()
      |> ClaudioStream.build_final_message()

    assert [%{"type" => "text", "text" => "Paris", "citations" => [citation]}] = message["content"]
    assert %{"type" => "char_location", "cited_text" => "Paris is the capital"} = citation
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/messages/stream_test.exs`
Expected: the new test FAILS — the final text block has no `"citations"` key (the delta hit the catch-all).

- [ ] **Step 3: Add the `citations_delta` clauses**

In `lib/claudio/messages/stream.ex`, add immediately before the catch-all `defp apply_delta(block, _delta), do: block` (alongside the Task 4 clauses):

```elixir
defp apply_delta(block, %{"type" => "citations_delta", "citation" => citation}) do
  current = block["citations"] || block[:citations] || []
  Map.put(block, "citations", current ++ [citation])
end

defp apply_delta(block, %{type: "citations_delta", citation: citation}) do
  current = block["citations"] || block[:citations] || []
  Map.put(block, "citations", current ++ [citation])
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/messages/stream_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/stream.ex test/messages/stream_test.exs
git commit -m "fix(stream): accumulate citations_delta on streamed blocks"
```

---

### Task 6: No-key round-trip proof (serialized payload assertion)

**Files:**
- Test: `test/response_test.exs`

**Interfaces:**
- Consumes: `Response.to_assistant_content/1` (Task 3), `Claudio.Messages.Request.add_message/3` + `to_map/1`.

This is the unit-level proof that a thinking + tool-use turn replays without losing the
fields the API requires — no API key needed.

- [ ] **Step 1: Add the alias and the test**

At the top of `test/response_test.exs`, add (below the existing `alias Claudio.Messages.Response`):

```elixir
alias Claudio.Messages.Request
```

Then add the test:

```elixir
describe "to_assistant_content/1 round-trip into a request payload" do
  test "serialized assistant turn carries signature and redacted data in API shape" do
    response = %Response{
      content: [
        %{type: :thinking, thinking: "reasoning", signature: "sig_abc"},
        %{type: :redacted_thinking, data: "enc_xyz"},
        %{type: :tool_use, id: "toolu_1", name: "get_weather", input: %{"location" => "NYC"}}
      ]
    }

    payload =
      Request.new("claude-x")
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.to_map()

    assert %{"messages" => [%{"role" => "assistant", "content" => content}]} = payload
    assert %{"type" => "thinking", "thinking" => "reasoning", "signature" => "sig_abc"} = Enum.at(content, 0)
    assert %{"type" => "redacted_thinking", "data" => "enc_xyz"} = Enum.at(content, 1)
    assert %{"type" => "tool_use", "id" => "toolu_1", "name" => "get_weather"} = Enum.at(content, 2)
  end
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `mix test test/response_test.exs`
Expected: PASS (Tasks 1–3 already implement everything this exercises; this test asserts they compose correctly).

- [ ] **Step 3: Commit**

```bash
git add test/response_test.exs
git commit -m "test(response): prove thinking+tool_use turn round-trips into request payload"
```

---

### Task 7: Integration round-trip test (`:integration`, excluded by default)

**Files:**
- Modify: `test/integration/messages_integration_test.exs`

**Interfaces:**
- Consumes: `create_client/0`, `skip_if_no_api_key/0`, `test_model/0` from `Claudio.IntegrationHelper`; `Response.to_assistant_content/1`.

Real end-to-end proof that replaying a thinking + tool-use turn does not 400. Requires
`ANTHROPIC_API_KEY` and a thinking-capable model; skipped otherwise, excluded from the
default suite.

- [ ] **Step 1: Add the integration test**

Add inside `Claudio.Messages.IntegrationTest` in `test/integration/messages_integration_test.exs`:

```elixir
describe "extended thinking round-trip" do
  test "replays a thinking + tool_use assistant turn without a 400", %{client: client} do
    tool = %{
      "name" => "get_weather",
      "description" => "Get the current weather for a location",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"location" => %{"type" => "string"}},
        "required" => ["location"]
      }
    }

    first =
      Request.new(test_model())
      |> Request.add_message(:user, "What's the weather in NYC? Use the tool.")
      |> Request.set_max_tokens(2048)
      |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 1024})
      |> Request.add_tool(tool)

    assert {:ok, response} = Messages.create(client, first)

    # Build the follow-up: replay the assistant turn (incl. thinking signature),
    # then answer any tool_use with a tool_result.
    tool_results =
      response
      |> Response.get_tool_uses()
      |> Enum.map(fn tu ->
        %{"type" => "tool_result", "tool_use_id" => tu.id, "content" => "Sunny, 72F"}
      end)

    second =
      Request.new(test_model())
      |> Request.add_message(:user, "What's the weather in NYC? Use the tool.")
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, tool_results)
      |> Request.set_max_tokens(2048)
      |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 1024})
      |> Request.add_tool(tool)

    # The point of the test: this must NOT return {:error, %APIError{status: 400}}.
    assert {:ok, %Response{}} = Messages.create(client, second)
  end
end
```

- [ ] **Step 2: Run the integration test explicitly**

Run: `mix test test/integration/messages_integration_test.exs --include integration`
Expected: PASS if `ANTHROPIC_API_KEY` is set and `test_model()` supports extended thinking; otherwise the module is skipped via `skip_if_no_api_key/0`. (If the model returns no `tool_use`, `tool_results` is `[]` and the second turn still asserts no 400 on the thinking-replay alone.)

- [ ] **Step 3: Commit**

```bash
git add test/integration/messages_integration_test.exs
git commit -m "test(integration): thinking + tool_use round-trip does not 400"
```

---

### Final verification

- [ ] **Run the full default suite**

Run: `mix test`
Expected: PASS, zero failures. (Integration tests excluded by default.)

- [ ] **Format check**

Run: `mix format --check-formatted`
Expected: clean. If it reports files, run `mix format` and amend the relevant commit.

- [ ] **Close the beads task**

Run: `bd close claudio-hms --reason="S1 implemented: thinking signature + redacted_thinking preserved, streaming signature_delta/citations_delta accumulated, to_assistant_content/1 added, tests green"`

## Self-review notes (coverage map)

- Spec §1 (response.ex: signature, redacted_thinking) → Tasks 1, 2.
- Spec §2 (stream.ex: signature_delta, citations_delta; redacted_thinking-streaming guard) → Tasks 4, 5.
- Spec §3 (to_assistant_content/1, no add_response/2) → Task 3.
- Spec §4 (unit parse/round-trip/stream tests; no-key payload proof; one :integration test) → Tasks 1–7.
- Spec §5 (out of scope: typed citations, request toggle) → not implemented here (S5).
