# S14 Tool Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tool search / `defer_loading` / `allowed_callers` / advisor helpers, client toolsets (`computer_toolset_20260801`, `browser_toolset_20260801`) with a working `toolset_name` round trip, `caller` and `container` plumbing for programmatic tool calling, shallow typing of server-result blocks, and an `Agent` loop that handles toolsets, containers and `pause_turn`.

**Architecture:** `Response` keeps `caller`/`toolset_name` on tool-use blocks and re-emits them, types six server-result blocks + `container_upload` shallowly (`raw:` replayed verbatim), and gains `container`. `Stream` carries the container. `Request` gains `add_tool/3` options and four tool helpers, plus an advisor replay beta in `add_message/3`. `Tools` exposes `toolset_name`/`caller`, echoes `toolset_name` on results, and builds the per-toolset halt result. `Agent` dispatches on the `(toolset_name, name)` pair, halts a failed toolset batch, carries the container and resumes `pause_turn`.

**Tech Stack:** Elixir ≥ 1.15, ExUnit (async), Bypass, Jason.

**Spec:** `docs/superpowers/specs/2026-09-26-s14-tool-extensions-design.md`

## Global Constraints

- Builds on S13: this plan assumes `feat/s13-context-management` is merged to `main` (it edits the post-S13 `add_message/3`, which ends with `add_compaction_replay_betas(request, content)`).
- Type strings, verbatim: `tool_search_tool_regex_20251119` / `tool_search_tool_regex`, `tool_search_tool_bm25_20251119` / `tool_search_tool_bm25`, `advisor_20260301` / `advisor`, `computer_toolset_20260801`, `browser_toolset_20260801`, `computer_20251124`, `computer_20250124`.
- Beta strings, verbatim: `advisor-tool-2026-03-01` (advisor tool + advisor replay), `computer-use-2025-11-24` (`computer_20251124`), `computer-use-2025-01-24` (`computer_20250124`). Tool search, PTC and both toolsets are GA — **no beta**.
- `allowed_callers` atom mapping: `:direct` → `"direct"`, `:code_execution` → `"code_execution_20260120"`.
- Halt texts, verbatim: computer `Not executed: an earlier computer action in this turn failed.`; browser `Not executed: an earlier action in this turn failed.`
- Dispatch rule (spec F11, Q 2026-09-26): a `tool_use` with `toolset_name` goes **only** to `handlers[toolset_name]` (arity 2: member, input); without it, to `handlers[name]` (arity 1).
- API-authoritative: member names, `configs` rules, F2/F6 rules, advisor pairing, result content types are not validated locally. `ArgumentError` only for shapes that can't be meant; unknown option keys raise via `Keyword.validate!/2`.
- Parsed-block shape change is additive: `tool_use` gains `caller`/`toolset_name`, `server_tool_use` gains `caller`, `web_search_tool_result` gains `caller`/`raw`. Hand-built typed maps without those keys must still replay (use `block[:key]`, not `block.key`).
- `add_tool/2` keeps its behavior; `create_tool_result/3` keeps its behavior; `Agent.run/4` return shapes unchanged. No `@version` bump; CHANGELOG under `## [Unreleased] — targets 0.7.0`.
- Commits: add files individually (`git add .` forbidden); **no AI attribution lines**.
- Gates before each commit: `mix format` and `mix compile --warnings-as-errors`; Task 7 ends with `mix format --check-formatted`, the full suite and the integration file.

## Pre-flight: re-verify facts

Before Task 1: `git log main --oneline -5` shows the S13 merge. Re-fetch
`platform.claude.com/docs/en/agents-and-tools/tool-use/tool-reference` and confirm the type strings,
the advisor beta and the "Dispatch on the `toolset_name` and `name` pair" guidance still appear;
re-fetch `…/computer-use-tool` and `…/browser-use-tool` and confirm both halt texts verbatim. If
anything changed, stop and ask Q.

## Review Focus

1. Hand-built typed blocks (`%{type: :tool_use, id:, name:, input:}` with no `caller`/`toolset_name` keys, `%{type: :web_search_tool_result, tool_use_id:, content:}` with no `raw`) must still replay exactly as today. Pinned in Task 1.
2. A custom client tool named like a toolset member (`"screenshot"`) must never receive toolset calls, and a toolset handler must never receive a plain call. Pinned in Task 5.
3. A batch halt applies only to the failing toolset: a plain tool and the other toolset in the same turn still run. Pinned in Task 5.
4. A streamed `message_delta` with `"container": null` must not erase the container from `message_start`. Pinned in Task 2.
5. `pause_turn` forever must end in `{:error, :max_turns_exceeded, _, _}`, not loop. Pinned in Task 5.

## Branching

Implementation branch `feat/s14-tool-extensions`, cut from `main` after S13 is merged (the plan files are on `docs/s13-s15-specs` and reach `main` with S13).

---

### Task 1: Response — `caller`/`toolset_name` round trip, shallow result typing, `container`

**Files:**
- Modify: `lib/claudio/messages/response.ex` — types (~lines 36-105), `@type t`/`defstruct`/`from_map/1` (~lines 140-185), new `get_server_tool_results/1,2` after `get_server_tool_uses/1` (~line 258), `tool_use` / `server_tool_use` / `web_search_tool_result` parse clauses (~lines 369-475), new parse clauses before the catch-all, `block_to_api/1` clauses (~lines 511-552)
- Test: `test/response_test.exs` — update the two exact assertions at ~lines 465 and 498; new describes at the end

**Interfaces:**
- Consumes: nothing new.
- Produces: `tool_use` block `%{type: :tool_use, id, name, input, caller, toolset_name}`; `server_tool_use` block adds `caller`; result blocks `%{type: atom, tool_use_id, content, caller, raw}` for `:web_search_tool_result`, `:web_fetch_tool_result`, `:code_execution_tool_result`, `:bash_code_execution_tool_result`, `:text_editor_code_execution_tool_result`, `:tool_search_tool_result`, `:advisor_tool_result`; `%{type: :container_upload, file_id, raw}`; `Response.get_server_tool_results(t()) :: [map()]`, `Response.get_server_tool_results(t(), atom()) :: [map()]`; struct field `container :: map() | nil`. Tasks 2, 4, 5 rely on these.

- [ ] **Step 1: Write the failing tests**

In `test/response_test.exs`, update the existing exact assertion for `server_tool_use` (~line 465) to:

```elixir
      assert block == %{
               type: :server_tool_use,
               id: "srvtoolu_1",
               name: "web_search",
               input: %{"query" => "elixir"},
               caller: nil
             }
```

and the one for `web_search_tool_result` (~line 498) to:

```elixir
      assert block == %{
               type: :web_search_tool_result,
               tool_use_id: "srvtoolu_1",
               content: @web_results,
               caller: nil,
               raw: hd(data["content"])
             }
```

Add at the end of the module (before the final `end`):

```elixir
  describe "tool_use caller and toolset_name (S14)" do
    @member %{
      "type" => "tool_use",
      "id" => "toolu_1",
      "name" => "screenshot",
      "input" => %{},
      "toolset_name" => "computer",
      "caller" => %{"type" => "direct"}
    }

    test "parsed and re-emitted by to_assistant_content/1 (a stripped toolset_name is a 400)" do
      response = Response.from_map(%{"content" => [@member]})

      assert [%{type: :tool_use, toolset_name: "computer", caller: %{"type" => "direct"}}] =
               response.content

      assert Response.to_assistant_content(response) == [@member]
    end

    test "absent: keys are nil and the replay is byte-identical to before" do
      plain = %{"type" => "tool_use", "id" => "toolu_2", "name" => "x", "input" => %{"a" => 1}}
      response = Response.from_map(%{"content" => [plain]})

      assert [%{toolset_name: nil, caller: nil}] = response.content
      assert Response.to_assistant_content(response) == [plain]
    end

    test "hand-built typed blocks without the new keys still replay (Review Focus 1)" do
      response = %Response{
        content: [
          %{type: :tool_use, id: "toolu_3", name: "x", input: %{}},
          %{type: :server_tool_use, id: "srv_1", name: "web_search", input: %{}},
          %{type: :web_search_tool_result, tool_use_id: "srv_1", content: []}
        ]
      }

      assert Response.to_assistant_content(response) == [
               %{"type" => "tool_use", "id" => "toolu_3", "name" => "x", "input" => %{}},
               %{"type" => "server_tool_use", "id" => "srv_1", "name" => "web_search", "input" => %{}},
               %{"type" => "web_search_tool_result", "tool_use_id" => "srv_1", "content" => []}
             ]
    end

    test "server_tool_use caller round-trips; atom-keyed tool_use reads toolset_name" do
      srv = %{
        "type" => "server_tool_use",
        "id" => "srvtoolu_1",
        "name" => "code_execution",
        "input" => %{"code" => "1"},
        "caller" => %{"type" => "direct"}
      }

      assert Response.to_assistant_content(Response.from_map(%{"content" => [srv]})) == [srv]

      atom = %{type: "tool_use", id: "t", name: "left_click", input: %{}, toolset_name: "computer"}
      assert [%{toolset_name: "computer"}] = Response.from_map(%{content: [atom]}).content
    end
  end

  describe "server-result blocks (S14)" do
    @results [
      {"web_fetch_tool_result", :web_fetch_tool_result},
      {"code_execution_tool_result", :code_execution_tool_result},
      {"bash_code_execution_tool_result", :bash_code_execution_tool_result},
      {"text_editor_code_execution_tool_result", :text_editor_code_execution_tool_result},
      {"tool_search_tool_result", :tool_search_tool_result},
      {"advisor_tool_result", :advisor_tool_result}
    ]

    for {string, atom} <- @results do
      @tag string: string, atom: atom
      test "#{string} parses shallowly and replays raw", %{string: string, atom: atom} do
        raw = %{
          "type" => string,
          "tool_use_id" => "srvtoolu_1",
          "content" => %{"type" => "some_variant", "x" => 1},
          "caller" => %{"type" => "direct"}
        }

        response = Response.from_map(%{"content" => [raw]})

        assert [
                 %{
                   type: ^atom,
                   tool_use_id: "srvtoolu_1",
                   content: %{"type" => "some_variant", "x" => 1},
                   caller: %{"type" => "direct"},
                   raw: ^raw
                 }
               ] = response.content

        assert Response.to_assistant_content(response) == [raw]
      end
    end

    test "atom-keyed result block" do
      raw = %{type: "tool_search_tool_result", tool_use_id: "s", content: %{}}

      assert [%{type: :tool_search_tool_result, tool_use_id: "s", caller: nil, raw: ^raw}] =
               Response.from_map(%{content: [raw]}).content
    end

    test "container_upload" do
      raw = %{"type" => "container_upload", "file_id" => "file_1"}
      response = Response.from_map(%{"content" => [raw]})

      assert [%{type: :container_upload, file_id: "file_1", raw: ^raw}] = response.content
      assert Response.to_assistant_content(response) == [raw]
    end

    test "web_search_tool_result caller now round-trips" do
      raw = %{
        "type" => "web_search_tool_result",
        "tool_use_id" => "s",
        "content" => [],
        "caller" => %{"type" => "direct"}
      }

      assert Response.to_assistant_content(Response.from_map(%{"content" => [raw]})) == [raw]
    end

    test "get_server_tool_results/1,2" do
      response =
        Response.from_map(%{
          "content" => [
            %{"type" => "server_tool_use", "id" => "a", "name" => "code_execution", "input" => %{}},
            %{"type" => "code_execution_tool_result", "tool_use_id" => "a", "content" => %{}},
            %{"type" => "text", "text" => "x"},
            %{"type" => "web_search_tool_result", "tool_use_id" => "b", "content" => []},
            %{"type" => "container_upload", "file_id" => "f"}
          ]
        })

      assert Enum.map(Response.get_server_tool_results(response), & &1.type) ==
               [:code_execution_tool_result, :web_search_tool_result, :container_upload]

      assert [%{tool_use_id: "b"}] =
               Response.get_server_tool_results(response, :web_search_tool_result)

      assert Response.get_server_tool_results(response, :advisor_tool_result) == []
    end
  end

  describe "from_map/1 container (S14)" do
    @container %{"id" => "container_1", "expires_at" => "2026-09-26T18:57:00Z"}

    test "kept raw, string and atom keys; nil when absent" do
      assert Response.from_map(%{"content" => [], "container" => @container}).container ==
               @container

      assert Response.from_map(%{content: [], container: @container}).container == @container
      assert Response.from_map(%{"content" => []}).container == nil
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/response_test.exs`
Expected: FAIL — the two updated exact assertions (missing `caller`/`raw`), the `toolset_name` replay test (re-emitted map lacks `"toolset_name"`/`"caller"`), each result-type test (block stays a raw string-keyed map), `container_upload`, `UndefinedFunctionError` for `get_server_tool_results/1`, `KeyError` for `:container`. "absent: … byte-identical" and "hand-built typed blocks" may already pass — they guard the change.

- [ ] **Step 3: Implement**

In `lib/claudio/messages/response.ex`:

1. Types — `tool_use_block` gains `caller: map() | nil, toolset_name: String.t() | nil`; `server_tool_use_block` gains `caller: map() | nil`; `web_search_tool_result_block` gains `caller: map() | nil, raw: map()`. Add after `web_search_tool_result_block`:

```elixir
  @typedoc """
  A server-tool result other than web search (`web_fetch_tool_result`,
  `code_execution_tool_result`, `bash_code_execution_tool_result`,
  `text_editor_code_execution_tool_result`, `tool_search_tool_result`,
  `advisor_tool_result`). `content` is the raw nested value (its variants and error codes
  change over time); `raw` is the block as received and is what
  `to_assistant_content/1` replays.
  """
  @type server_tool_result_block :: %{
          type: atom(),
          tool_use_id: String.t(),
          content: term(),
          caller: map() | nil,
          raw: map()
        }

  @type container_upload_block :: %{type: :container_upload, file_id: String.t(), raw: map()}
```

   and add `| server_tool_result_block() | container_upload_block()` to `@type content_block`.

2. `@type t` — add `container: map() | nil,` after `context_management`; `defstruct` — add `:container` after `:context_management`; `from_map/1` — add `container: data[:container] || data["container"],`.

3. Directly **above** `get_server_tool_uses/1`'s `@doc` (attributes must precede their first use, and `get_server_tool_results/1` below uses them), add:

```elixir
  # Server-tool result blocks typed shallowly (S14): content stays raw, raw is replayed.
  @server_result_types %{
    "web_fetch_tool_result" => :web_fetch_tool_result,
    "code_execution_tool_result" => :code_execution_tool_result,
    "bash_code_execution_tool_result" => :bash_code_execution_tool_result,
    "text_editor_code_execution_tool_result" => :text_editor_code_execution_tool_result,
    "tool_search_tool_result" => :tool_search_tool_result,
    "advisor_tool_result" => :advisor_tool_result
  }
  @server_result_atoms Map.values(@server_result_types)
```

4. Replace the two `tool_use` parse clauses with:

```elixir
  defp parse_content_block(%{type: "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block[:id],
      name: block[:name],
      input: block[:input],
      caller: block[:caller],
      toolset_name: block[:toolset_name]
    }
  end

  defp parse_content_block(%{"type" => "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block["id"],
      name: block["name"],
      input: block["input"],
      caller: block["caller"],
      toolset_name: block["toolset_name"]
    }
  end
```

5. In both `server_tool_use` parse clauses add `caller: block[:caller]` / `caller: block["caller"]`. Replace both `web_search_tool_result` clauses with:

```elixir
  defp parse_content_block(%{type: "web_search_tool_result"} = block) do
    %{
      type: :web_search_tool_result,
      tool_use_id: block[:tool_use_id],
      content: block[:content],
      caller: block[:caller],
      raw: block
    }
  end

  defp parse_content_block(%{"type" => "web_search_tool_result"} = block) do
    %{
      type: :web_search_tool_result,
      tool_use_id: block["tool_use_id"],
      content: block["content"],
      caller: block["caller"],
      raw: block
    }
  end
```

6. Before the catch-all `defp parse_content_block(block), do: block`, add:

```elixir
  defp parse_content_block(%{"type" => type} = block)
       when is_map_key(@server_result_types, type) do
    %{
      type: Map.fetch!(@server_result_types, type),
      tool_use_id: block["tool_use_id"],
      content: block["content"],
      caller: block["caller"],
      raw: block
    }
  end

  defp parse_content_block(%{type: type} = block) when is_map_key(@server_result_types, type) do
    %{
      type: Map.fetch!(@server_result_types, type),
      tool_use_id: block[:tool_use_id],
      content: block[:content],
      caller: block[:caller],
      raw: block
    }
  end

  defp parse_content_block(%{"type" => "container_upload"} = block),
    do: %{type: :container_upload, file_id: block["file_id"], raw: block}

  defp parse_content_block(%{type: "container_upload"} = block),
    do: %{type: :container_upload, file_id: block[:file_id], raw: block}
```

7. `block_to_api/1` — replace the `:tool_use`, `:server_tool_use` and `:web_search_tool_result` clauses with:

```elixir
  defp block_to_api(%{type: :tool_use, id: id, name: name, input: input} = block) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
    |> put_present("caller", block[:caller])
    |> put_present("toolset_name", block[:toolset_name])
  end
```

```elixir
  defp block_to_api(%{type: :server_tool_use} = block) do
    %{
      "type" => "server_tool_use",
      "id" => block.id,
      "name" => block.name,
      "input" => block.input
    }
    |> put_present("caller", block[:caller])
  end

  defp block_to_api(%{type: :web_search_tool_result, raw: raw}) when is_map(raw), do: raw

  defp block_to_api(%{type: :web_search_tool_result} = block) do
    %{
      "type" => "web_search_tool_result",
      "tool_use_id" => block.tool_use_id,
      "content" => block.content
    }
  end
```

   and after the `:compaction` clause (S13) add:

```elixir
  defp block_to_api(%{type: :container_upload, raw: raw}), do: raw
  defp block_to_api(%{type: type, raw: raw}) when type in @server_result_atoms, do: raw
```

   plus a helper near `field/2`:

```elixir
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
```

   (The `tool_use` clause keeps rebuilding rather than returning `raw`: a streamed `tool_use` carries an undecoded `"partial_json"` key that must not be replayed — spec F18.)

8. After `get_server_tool_uses/1`, add:

```elixir
  @doc """
  Returns server-tool result blocks in content order: `web_search_tool_result`,
  `web_fetch_tool_result`, `code_execution_tool_result`, `bash_code_execution_tool_result`,
  `text_editor_code_execution_tool_result`, `tool_search_tool_result`, `advisor_tool_result`
  and `container_upload`. `content` is the raw nested value.
  """
  @spec get_server_tool_results(t()) :: [map()]
  def get_server_tool_results(%__MODULE__{content: content}) do
    types = [:web_search_tool_result, :container_upload | @server_result_atoms]
    Enum.filter(content, &(is_map(&1) and &1[:type] in types))
  end

  @doc "Returns the server-tool result blocks of one type (e.g. `:code_execution_tool_result`)."
  @spec get_server_tool_results(t(), atom()) :: [map()]
  def get_server_tool_results(%__MODULE__{content: content}, type) when is_atom(type) do
    Enum.filter(content, &(is_map(&1) and &1[:type] == type))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: PASS, 0 failures (full suite: `tools_test`, `agent_test`, `mcp/result_mapper_test` read tool-use blocks and must stay green).

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/response.ex test/response_test.exs
git commit -m "feat(s14): round-trip caller/toolset_name, type server-result blocks, Response.container"
```

---
### Task 2: Stream — carry `container`

**Files:**
- Modify: `lib/claudio/messages/stream.ex` — the `message_delta` clause of `build_final_message/1` (~line 270)
- Test: `test/messages/stream_test.exs` — new describe at the end

**Interfaces:**
- Consumes: Task 1's `Response.container`.
- Produces: `build_final_message/1` keeps `message_start.message["container"]` and overwrites it with a non-nil `message_delta.delta["container"]`.

- [ ] **Step 1: Write the failing test**

```elixir
  describe "build_final_message/1 container (S14)" do
    defp container_stream(start_container, delta_container) do
      [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","content":[],"model":"x","container":#{Jason.encode!(start_container)},"usage":{"input_tokens":1,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"tool_use","container":#{Jason.encode!(delta_container)}},"usage":{"output_tokens":1}}),
        ""
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> List.wrap()
      |> ClaudioStream.parse_events()
      |> ClaudioStream.build_final_message()
    end

    test "message_start container survives a null delta container (Review Focus 4)" do
      c = %{"id" => "container_1", "expires_at" => "t1"}
      {:ok, message} = container_stream(c, nil)

      assert Claudio.Messages.Response.from_map(message).container == c
    end

    test "a non-null delta container overwrites the start value" do
      {:ok, message} =
        container_stream(%{"id" => "container_1", "expires_at" => "t1"}, %{
          "id" => "container_1",
          "expires_at" => "t2"
        })

      assert message["container"] == %{"id" => "container_1", "expires_at" => "t2"}
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/messages/stream_test.exs`
Expected: the first test PASSES already (message_start is stored whole and Task 1 reads `container`); the second FAILS (`expires_at` stays `"t1"`).

- [ ] **Step 3: Implement**

In the `message_delta` clause pipeline, after `|> maybe_update(delta, "stop_details")`, add:

```elixir
            # Programmatic tool calling: the container may be refreshed here (S14).
            |> maybe_update(delta, "container")
```

(`maybe_update/3` skips `nil`, which is what keeps the start value on `"container": null`.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix format && mix compile --warnings-as-errors && mix test test/messages/stream_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/stream.ex test/messages/stream_test.exs
git commit -m "feat(s14): stream carries message_delta container"
```

---

### Task 3: Request — `add_tool/3`, tool search, advisor, toolsets, computer version, advisor replay beta

**Files:**
- Modify: `lib/claudio/messages/request.ex` — `add_tool/2` (~line 443) becomes `add_tool/3`; new functions after `add_tool_with_eager_streaming/2` (~line 1060); `add_computer_tool/4` (~line 1185); `@advisor_beta` next to the S13 attributes (near `@fallback_beta`); `add_message/3` and helpers (~lines 95-160)
- Test: `test/request_test.exs` — extend `describe "add_computer_tool/4 (S6)"`; new describes after it; new describe after `describe "add_message/3 with a compaction block"` (S13)

**Interfaces:**
- Consumes: `add_beta/2`, `maybe_put/3`, `add_message/3` post-S13.
- Produces: `add_tool(t(), map(), keyword()) :: t()`; `add_tool_search_tool(t(), :regex | :bm25) :: t()`; `add_advisor_tool(t(), String.t(), keyword()) :: t()`; `add_computer_toolset(t(), keyword()) :: t()`; `add_browser_toolset(t(), keyword()) :: t()`; `add_computer_tool/4` `version:` option; `add_message/3` declares `advisor-tool-2026-03-01` for advisor blocks. Task 6 uses all of them.

- [ ] **Step 1: Write the failing tests**

Inside `describe "add_computer_tool/4 (S6)"`, add:

```elixir
    test "version: :\"20251124\" emits computer_20251124 with its beta" do
      request =
        Request.new("claude-opus-4-8")
        |> Request.add_computer_tool(1280, 800, version: :"20251124")

      assert [%{"type" => "computer_20251124", "name" => "computer"}] =
               Request.to_map(request)["tools"]

      assert Request.required_betas(request) == ["computer-use-2025-11-24"]
    end

    test "an unknown version raises" do
      assert_raise ArgumentError, ~r/add_computer_tool\/4 :version/, fn ->
        Request.add_computer_tool(Request.new("m"), 1, 1, version: :"20260801")
      end
    end
```

After that describe, add:

```elixir
  describe "add_tool/3 (S14)" do
    @tool %{"name" => "t", "description" => "d", "input_schema" => %{"type" => "object"}}

    test "defer_loading and allowed_callers" do
      request =
        Request.new("m")
        |> Request.add_tool(@tool,
          defer_loading: true,
          allowed_callers: [:direct, :code_execution, "code_execution_20260521"]
        )

      assert Request.to_map(request)["tools"] == [
               Map.merge(@tool, %{
                 "defer_loading" => true,
                 "allowed_callers" => ["direct", "code_execution_20260120", "code_execution_20260521"]
               })
             ]

      assert Request.required_betas(request) == []
    end

    test "add_tool/2 and add_tool/3 with [] leave the tool unchanged" do
      assert Request.to_map(Request.add_tool(Request.new("m"), @tool))["tools"] == [@tool]
      assert Request.to_map(Request.add_tool(Request.new("m"), @tool, []))["tools"] == [@tool]
    end

    test "invalid options raise" do
      r = Request.new("m")
      assert_raise ArgumentError, fn -> Request.add_tool(r, @tool, bogus: 1) end

      assert_raise ArgumentError, ~r/add_tool\/3 :defer_loading/, fn ->
        Request.add_tool(r, @tool, defer_loading: "yes")
      end

      assert_raise ArgumentError, ~r/add_tool\/3 :allowed_callers/, fn ->
        Request.add_tool(r, @tool, allowed_callers: :direct)
      end

      assert_raise ArgumentError, ~r/add_tool\/3 :allowed_callers/, fn ->
        Request.add_tool(r, @tool, allowed_callers: [:sandbox])
      end
    end
  end

  describe "add_tool_search_tool/2 (S14)" do
    test "regex and bm25 variants, no beta" do
      for {variant, type, name} <- [
            {:regex, "tool_search_tool_regex_20251119", "tool_search_tool_regex"},
            {:bm25, "tool_search_tool_bm25_20251119", "tool_search_tool_bm25"}
          ] do
        request = Request.new("m") |> Request.add_tool_search_tool(variant)
        assert Request.to_map(request)["tools"] == [%{"type" => type, "name" => name}]
        assert Request.required_betas(request) == []
      end
    end

    test "other variants raise" do
      assert_raise ArgumentError, ~r/add_tool_search_tool\/2/, fn ->
        Request.add_tool_search_tool(Request.new("m"), :fuzzy)
      end
    end
  end

  describe "add_advisor_tool/3 (S14)" do
    test "minimal: type, name, model, beta" do
      request = Request.new("claude-sonnet-5") |> Request.add_advisor_tool("claude-opus-5-5")

      assert Request.to_map(request)["tools"] == [
               %{"type" => "advisor_20260301", "name" => "advisor", "model" => "claude-opus-5-5"}
             ]

      assert Request.required_betas(request) == ["advisor-tool-2026-03-01"]
    end

    test "all options" do
      request =
        Request.new("m")
        |> Request.add_advisor_tool("claude-opus-5-5", max_uses: 3, max_tokens: 2048, caching: "1h")

      assert [
               %{
                 "max_uses" => 3,
                 "max_tokens" => 2048,
                 "caching" => %{"type" => "ephemeral", "ttl" => "1h"}
               }
             ] = Request.to_map(request)["tools"]
    end

    test "bad caching and unknown options raise" do
      assert_raise ArgumentError, ~r/add_advisor_tool\/3 :caching/, fn ->
        Request.add_advisor_tool(Request.new("m"), "x", caching: "2h")
      end

      assert_raise ArgumentError, fn -> Request.add_advisor_tool(Request.new("m"), "x", foo: 1) end
    end
  end

  describe "client toolsets (S14)" do
    test "add_computer_toolset/1: bare entry, no name, no beta" do
      request = Request.new("claude-opus-5-5") |> Request.add_computer_toolset()

      assert Request.to_map(request)["tools"] == [%{"type" => "computer_toolset_20260801"}]
      assert Request.required_betas(request) == []
    end

    test "configs keys are stringified; cache_control passes through" do
      request =
        Request.new("m")
        |> Request.add_browser_toolset(
          configs: %{javascript_exec: %{enabled: true}, "zoom" => %{"defer_loading" => false}},
          cache_control: %{"type" => "ephemeral"}
        )

      assert Request.to_map(request)["tools"] == [
               %{
                 "type" => "browser_toolset_20260801",
                 "configs" => %{
                   "javascript_exec" => %{"enabled" => true},
                   "zoom" => %{"defer_loading" => false}
                 },
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]
    end

    test "unknown options raise" do
      assert_raise ArgumentError, fn -> Request.add_computer_toolset(Request.new("m"), name: "x") end
    end
  end
```

After `describe "add_message/3 with a compaction block"` (S13), add:

```elixir
  describe "add_message/3 with advisor blocks (S14)" do
    test "an advisor result or advisor server_tool_use declares the advisor beta" do
      for block <- [
            %{"type" => "advisor_tool_result", "tool_use_id" => "s", "content" => %{}},
            %{"type" => "server_tool_use", "id" => "s", "name" => "advisor", "input" => %{}},
            %{type: :server_tool_use, id: "s", name: "advisor", input: %{}},
            %{type: :advisor_tool_result, tool_use_id: "s", content: %{}, caller: nil, raw: %{}}
          ] do
        request = Request.new("m") |> Request.add_message(:assistant, [block])
        assert Request.required_betas(request) == ["advisor-tool-2026-03-01"]
      end
    end

    test "other server tools declare nothing" do
      block = %{"type" => "server_tool_use", "id" => "s", "name" => "web_search", "input" => %{}}
      assert Request.required_betas(Request.add_message(Request.new("m"), :assistant, [block])) == []
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/request_test.exs`
Expected: FAIL — `UndefinedFunctionError` for `add_tool/3`, `add_tool_search_tool/2`, `add_advisor_tool/2,3`, `add_computer_toolset/1,2`, `add_browser_toolset/2`; the computer `version:` test gets `computer_20250124`; the unknown-version test doesn't raise; the advisor `add_message/3` test gets `[]`.

- [ ] **Step 3: Implement**

1. Replace `add_tool/2` (keep its `@doc`, append the options section) with:

```elixir
  @spec add_tool(t(), map(), keyword()) :: t()
  def add_tool(%__MODULE__{tools: tools} = request, tool, opts \\ [])
      when is_map(tool) and is_list(opts) do
    opts = Keyword.validate!(opts, [:defer_loading, :allowed_callers])

    tool =
      tool
      |> maybe_put("defer_loading", defer_loading!(Keyword.get(opts, :defer_loading)))
      |> maybe_put("allowed_callers", allowed_callers!(Keyword.get(opts, :allowed_callers)))

    %{request | tools: (tools || []) ++ [tool]}
  end

  defp defer_loading!(value) when is_boolean(value) or is_nil(value), do: value

  defp defer_loading!(other) do
    raise ArgumentError,
          "Request.add_tool/3 :defer_loading must be a boolean; got #{inspect(other)}"
  end

  defp allowed_callers!(nil), do: nil
  defp allowed_callers!(callers) when is_list(callers), do: Enum.map(callers, &allowed_caller!/1)

  defp allowed_callers!(other) do
    raise ArgumentError,
          "Request.add_tool/3 :allowed_callers must be a list; got #{inspect(other)}"
  end

  defp allowed_caller!(:direct), do: "direct"
  # Responses always tag programmatic calls as code_execution_20260120 (tool-reference).
  defp allowed_caller!(:code_execution), do: "code_execution_20260120"
  defp allowed_caller!(caller) when is_binary(caller), do: caller

  defp allowed_caller!(other) do
    raise ArgumentError,
          "Request.add_tool/3 :allowed_callers entries must be :direct, :code_execution " <>
            "or a string; got #{inspect(other)}"
  end
```

   Append to `add_tool`'s `@doc`:

```
  ## Options

  - `:defer_loading` — `true` keeps the tool out of the initial prompt until a tool search
    tool (`add_tool_search_tool/2`) returns a reference to it. At least one tool must stay
    non-deferred.
  - `:allowed_callers` — who may call the tool: `:direct` (the model; the default when
    omitted), `:code_execution` (code inside a `code_execution_20260120`+ sandbox —
    programmatic tool calling), or a raw string.
```

2. After `add_tool_with_eager_streaming/2`, add:

```elixir
  @doc """
  Adds a tool search tool (GA, no beta) so tools added with `defer_loading: true` are
  found on demand: `:regex` (`tool_search_tool_regex_20251119`) or `:bm25`
  (`tool_search_tool_bm25_20251119`).
  """
  @spec add_tool_search_tool(t(), :regex | :bm25) :: t()
  def add_tool_search_tool(%__MODULE__{} = request, variant) when variant in [:regex, :bm25] do
    name = "tool_search_tool_#{variant}"
    add_tool(request, %{"type" => "#{name}_20251119", "name" => name})
  end

  def add_tool_search_tool(%__MODULE__{}, other) do
    raise ArgumentError,
          "Request.add_tool_search_tool/2 variant must be :regex or :bm25; got #{inspect(other)}"
  end

  @advisor_cache_ttls ["5m", "1h"]

  @doc """
  Adds the advisor tool (`advisor_20260301`; declares `advisor-tool-2026-03-01`): the model
  can consult `model` mid-task. Replaying advisor blocks later also needs the beta —
  `add_message/3` declares it.

  ## Options

  - `:max_uses` — advisor calls per request
  - `:max_tokens` — advisor output cap (API minimum 1024)
  - `:caching` — `"5m"` or `"1h"`: caches the advisor's context
  """
  @spec add_advisor_tool(t(), String.t(), keyword()) :: t()
  def add_advisor_tool(%__MODULE__{} = request, model, opts \\ [])
      when is_binary(model) and is_list(opts) do
    opts = Keyword.validate!(opts, [:max_uses, :max_tokens, :caching])

    caching =
      case Keyword.get(opts, :caching) do
        nil ->
          nil

        ttl when ttl in @advisor_cache_ttls ->
          %{"type" => "ephemeral", "ttl" => ttl}

        other ->
          raise ArgumentError,
                "Request.add_advisor_tool/3 :caching must be \"5m\" or \"1h\"; got #{inspect(other)}"
      end

    tool =
      %{"type" => "advisor_20260301", "name" => "advisor", "model" => model}
      |> maybe_put("max_uses", Keyword.get(opts, :max_uses))
      |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
      |> maybe_put("caching", caching)

    request |> add_tool(tool) |> add_beta(@advisor_beta)
  end

  @doc """
  Adds the computer use client toolset (`computer_toolset_20260801`, GA, no beta) — the
  computer tool Claude Opus 5.5 accepts. Each action arrives as its own `tool_use` whose
  `name` is the member (`"screenshot"`, `"left_click"`, …) and whose `toolset_name` is
  `"computer"`; every `tool_result` must echo `toolset_name`
  (`Claudio.Tools.create_tool_result/4`). See `Claudio.Agent` for a loop that does this.

  ## Options

  - `:configs` — `%{member => %{enabled: boolean, defer_loading: boolean}}`
  - `:cache_control` — cache breakpoint on the entry
  """
  @spec add_computer_toolset(t(), keyword()) :: t()
  def add_computer_toolset(%__MODULE__{} = request, opts \\ []),
    do: add_toolset(request, "computer_toolset_20260801", opts)

  @doc """
  Adds the browser use client toolset (`browser_toolset_20260801`, GA, no beta). Same
  mechanics and options as `add_computer_toolset/2`, with `toolset_name` `"browser"`.
  """
  @spec add_browser_toolset(t(), keyword()) :: t()
  def add_browser_toolset(%__MODULE__{} = request, opts \\ []),
    do: add_toolset(request, "browser_toolset_20260801", opts)

  defp add_toolset(request, type, opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:configs, :cache_control])

    configs =
      case Keyword.get(opts, :configs) do
        nil -> nil
        configs -> Map.new(configs, fn {member, conf} -> {to_string(member), stringify_keys(conf)} end)
      end

    tool =
      %{"type" => type}
      |> maybe_put("configs", configs)
      |> maybe_put("cache_control", Keyword.get(opts, :cache_control))

    add_tool(request, tool)
  end
```

   If `request.ex` has no `stringify_keys/1` helper yet, add:

```elixir
  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
```

   (Check first with `grep -n "defp stringify_keys" lib/claudio/messages/request.ex`; reuse an existing one if its semantics match.)

3. `add_computer_tool/4` — replace the body with:

```elixir
    {type, beta} =
      case Keyword.get(opts, :version) do
        nil -> {"computer_20250124", "computer-use-2025-01-24"}
        :"20251124" -> {"computer_20251124", "computer-use-2025-11-24"}
        other ->
          raise ArgumentError,
                "Request.add_computer_tool/4 :version must be :\"20251124\" or omitted; " <>
                  "got #{inspect(other)} (use add_computer_toolset/2 for computer_toolset_20260801)"
      end

    tool =
      %{
        "type" => type,
        "name" => "computer",
        "display_width_px" => display_width_px,
        "display_height_px" => display_height_px
      }
      |> maybe_put("display_number", Keyword.get(opts, :display_number))

    request
    |> add_beta(beta)
    |> add_tool(tool)
```

   and add to its `@doc`: `- `:version` — `:"20251124"` for `computer_20251124` (declares `computer-use-2025-11-24`). Claude Opus 5.5 accepts only the toolset: use `add_computer_toolset/2`.`

4. Next to the S13 attributes (near `@fallback_beta`), add:

```elixir
  # Advisor tool; also needed to replay advisor blocks (probed 2026-09-26).
  @advisor_beta "advisor-tool-2026-03-01"
```

5. In `add_message/3`, replace the final `add_compaction_replay_betas(request, content)` with:

```elixir
    request = add_compaction_replay_betas(request, content)

    # Replaying advisor blocks needs the advisor beta even without the tool (probed 2026-09-26).
    if has_advisor_block?(content), do: add_beta(request, @advisor_beta), else: request
```

   and add next to the other `add_message` helpers:

```elixir
  defp has_advisor_block?(content) when is_list(content), do: Enum.any?(content, &advisor_block?/1)
  defp has_advisor_block?(_content), do: false

  defp advisor_block?(block) when is_map(block) do
    type = Map.get(block, "type") || Map.get(block, :type)
    name = Map.get(block, "name") || Map.get(block, :name)

    type in ["advisor_tool_result", :advisor_tool_result] or
      (type in ["server_tool_use", :server_tool_use] and name == "advisor")
  end

  defp advisor_block?(_block), do: false
```

   Append to `add_message/3`'s `@doc`: `Advisor blocks (\`advisor_tool_result\`, or a \`server_tool_use\` named \`"advisor"\`) declare \`advisor-tool-2026-03-01\`.`

- [ ] **Step 4: Run to verify it passes**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: PASS, 0 failures (full suite — every existing `add_tool/2` caller goes through the new default).

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(s14): add_tool/3 options, tool search, advisor, client toolsets, computer_20251124"
```

---

### Task 4: Tools — `toolset_name`/`caller`, `create_tool_result/4`, `halt_result/1`

**Files:**
- Modify: `lib/claudio/tools.ex` — `@type tool_use` / `@type tool_result`, `create_tool_result/3` (~line 175), `normalize_tool_use/1` clauses (~lines 241-253), new `halt_result/1` after `create_tool_result`
- Test: `test/tools_test.exs` — extend `describe "extract_tool_uses/1"` and `describe "create_tool_result/3"`; new describe `"halt_result/1"`

**Interfaces:**
- Consumes: Task 1's parsed `tool_use` with `caller`/`toolset_name`.
- Produces: `extract_tool_uses/1 :: [%{id, name, input, toolset_name, caller}]`; `create_tool_result(String.t(), term(), boolean(), keyword()) :: tool_result()` (`toolset_name:`); `halt_result(%{id: String.t(), toolset_name: "computer" | "browser"}) :: tool_result()`. Task 5 uses all three.

- [ ] **Step 1: Write the failing tests**

In `describe "extract_tool_uses/1"`, add:

```elixir
    test "exposes toolset_name and caller (nil when absent), for raw maps and Responses" do
      raw = %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "left_click",
            "input" => %{"coordinate" => [1, 2]},
            "toolset_name" => "computer",
            "caller" => %{"type" => "direct"}
          },
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "x", "input" => %{}}
        ]
      }

      expected = [
        %{
          id: "toolu_1",
          name: "left_click",
          input: %{"coordinate" => [1, 2]},
          toolset_name: "computer",
          caller: %{"type" => "direct"}
        },
        %{id: "toolu_2", name: "x", input: %{}, toolset_name: nil, caller: nil}
      ]

      assert Tools.extract_tool_uses(raw) == expected
      assert Tools.extract_tool_uses(Claudio.Messages.Response.from_map(raw)) == expected
    end
```

In `describe "create_tool_result/3"`, add:

```elixir
    test "create_tool_result/4 echoes toolset_name" do
      result = Tools.create_tool_result("toolu_1", "OK", false, toolset_name: "computer")

      assert result == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_1",
               "content" => "OK",
               "toolset_name" => "computer"
             }
    end

    test "create_tool_result/4 rejects unknown options" do
      assert_raise ArgumentError, fn -> Tools.create_tool_result("t", "x", false, foo: 1) end
    end
```

Add a new describe:

```elixir
  describe "halt_result/1" do
    test "exact halt text per toolset, is_error, toolset_name echoed" do
      assert Tools.halt_result(%{id: "toolu_1", toolset_name: "computer"}) == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_1",
               "content" => "Not executed: an earlier computer action in this turn failed.",
               "is_error" => true,
               "toolset_name" => "computer"
             }

      assert Tools.halt_result(%{id: "toolu_2", toolset_name: "browser"})["content"] ==
               "Not executed: an earlier action in this turn failed."
    end

    test "a plain tool use raises" do
      assert_raise ArgumentError, ~r/halt_result\/1/, fn ->
        Tools.halt_result(%{id: "toolu_1", toolset_name: nil})
      end
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tools_test.exs`
Expected: FAIL — `extract_tool_uses/1` returns maps without `toolset_name`/`caller`; `create_tool_result/4` undefined; `halt_result/1` undefined.

- [ ] **Step 3: Implement**

In `lib/claudio/tools.ex`:

1. `@type tool_use` gains `toolset_name: String.t() | nil, caller: map() | nil`.
2. Replace the three specific `normalize_tool_use/1` clauses (keep the catch-all) with:

```elixir
  defp normalize_tool_use(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = b) do
    %{id: id, name: name, input: input, toolset_name: b["toolset_name"], caller: b["caller"]}
  end

  defp normalize_tool_use(%{type: type, id: id, name: name, input: input} = b)
       when type in ["tool_use", :tool_use] do
    %{id: id, name: name, input: input, toolset_name: b[:toolset_name], caller: b[:caller]}
  end
```

3. Replace `create_tool_result/3`'s head and the final pipeline:

```elixir
  @spec create_tool_result(String.t(), String.t() | list() | map(), boolean(), keyword()) ::
          tool_result()
  def create_tool_result(tool_use_id, result, is_error \\ false, opts \\ [])
      when is_binary(tool_use_id) and is_list(opts) do
    opts = Keyword.validate!(opts, [:toolset_name])
```

   keep the existing `base` / `content` code, then end with:

```elixir
    base
    |> Map.put("content", content)
    |> maybe_put_error(is_error)
    |> maybe_put_toolset(Keyword.get(opts, :toolset_name))
  end
```

   Add to its `@doc`:

```
  - `opts` — `toolset_name:` echoes the `tool_use`'s `toolset_name` (required for results
    answering a client-toolset member call; the API rejects them without it).
```

   and the private helper:

```elixir
  defp maybe_put_toolset(map, nil), do: map
  defp maybe_put_toolset(map, toolset_name), do: Map.put(map, "toolset_name", toolset_name)
```

4. After `create_tool_result/4`, add:

```elixir
  # Exact texts from the computer-use and browser-use tool docs ("Batch actions").
  @halt_texts %{
    "computer" => "Not executed: an earlier computer action in this turn failed.",
    "browser" => "Not executed: an earlier action in this turn failed."
  }

  @doc """
  The result for a client-toolset action skipped because an earlier action in the same
  turn failed: `is_error: true`, the exact text the toolset contract prescribes, and
  `toolset_name` echoed. Takes a tool use from `extract_tool_uses/1`.
  """
  @spec halt_result(tool_use()) :: tool_result()
  def halt_result(%{id: id, toolset_name: toolset_name} = tool_use) do
    case Map.fetch(@halt_texts, toolset_name) do
      {:ok, text} ->
        create_tool_result(id, text, true, toolset_name: toolset_name)

      :error ->
        raise ArgumentError,
              "Tools.halt_result/1 needs a computer or browser toolset tool use; " <>
                "got #{inspect(tool_use)}"
    end
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/tools.ex test/tools_test.exs
git commit -m "feat(s14): Tools exposes toolset_name/caller, create_tool_result/4, halt_result/1"
```

---
### Task 5: Agent — pair dispatch, batch halt, container, `pause_turn`

**Files:**
- Modify: `lib/claudio/agent.ex` — moduledoc handler section (~lines 20-45), `@type handler(s)` (~line 50), `loop/6` (~lines 84-115), `execute_tools/3` (~lines 118-145), new private helpers
- Test: `test/agent_test.exs` — new `describe "run/4 toolsets, containers and pause_turn (S14)"` after `describe "run/4"`

**Interfaces:**
- Consumes: Task 1 `Response.container`, parsed `toolset_name`/`caller`; Task 4 `Tools.extract_tool_uses/1` (with `toolset_name`), `Tools.create_tool_result/4`, `Tools.halt_result/1`; existing `Request.set_container/2`.
- Produces: `Agent.run/4` behavior per spec §5. Task 6 uses it live.

- [ ] **Step 1: Write the failing tests**

Add after `describe "run/4"` in `test/agent_test.exs`. The Bypass handler sends each decoded request body to the test process so the follow-up requests can be asserted:

```elixir
  describe "run/4 toolsets, containers and pause_turn (S14)" do
    defp message(content, stop_reason, extra \\ %{}) do
      Map.merge(
        %{
          "id" => "msg_#{System.unique_integer([:positive])}",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => content,
          "stop_reason" => stop_reason,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        extra
      )
    end

    defp member(id, name, toolset \\ "computer") do
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}, "toolset_name" => toolset}
    end

    defp plain(id, name), do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}}

    # Serves `responses` in order and forwards every request body to the test process.
    defp serve(bypass, responses) do
      test_pid = self()
      count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        :counters.add(count, 1, 1)
        json_response(conn, Enum.at(responses, :counters.get(count, 1) - 1))
      end)
    end

    defp tool_results(body) do
      body["messages"] |> List.last() |> Map.fetch!("content")
    end

    test "pair dispatch: a custom screenshot tool never gets toolset calls (Review Focus 2)", %{
      client: client,
      bypass: bypass
    } do
      serve(bypass, [
        message([member("t1", "screenshot"), plain("t2", "screenshot")], "tool_use"),
        message([%{"type" => "text", "text" => "done"}], "end_turn")
      ])

      handlers = %{
        "computer" => fn member, input -> {:ok, "computer:#{member}:#{map_size(input)}"} end,
        "screenshot" => fn _input -> {:ok, "custom"} end
      }

      assert {:ok, _response, _messages} = Agent.run(client, base_request(), handlers)

      assert_received {:request_body, _first}
      assert_received {:request_body, second}

      assert [
               %{"tool_use_id" => "t1", "content" => "computer:screenshot:0", "toolset_name" => "computer"},
               %{"tool_use_id" => "t2", "content" => "custom"} = custom
             ] = tool_results(second)

      refute Map.has_key?(custom, "toolset_name")

      # The replayed assistant turn keeps toolset_name (a stripped one is a 400).
      assistant = Enum.at(second["messages"], -2)
      assert %{"toolset_name" => "computer"} = hd(assistant["content"])
    end

    test "a missing toolset handler is an error result with toolset_name echoed", %{
      client: client,
      bypass: bypass
    } do
      serve(bypass, [
        message([member("t1", "navigate", "browser")], "tool_use"),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      assert {:ok, _, _} = Agent.run(client, base_request(), %{})
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert [
               %{
                 "is_error" => true,
                 "content" => "Unknown toolset: browser",
                 "toolset_name" => "browser"
               }
             ] = tool_results(second)
    end

    test "batch halt: later calls of the failing toolset are skipped; others still run (Review Focus 3)",
         %{client: client, bypass: bypass} do
      serve(bypass, [
        message(
          [
            member("c1", "left_click"),
            member("c2", "type"),
            plain("p1", "lookup"),
            member("b1", "navigate", "browser"),
            member("c3", "key")
          ],
          "tool_use"
        ),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      test_pid = self()

      handlers = %{
        "computer" => fn
          "left_click", _ -> {:ok, "clicked"}
          "type", _ -> {:error, "keyboard unavailable"}
          other, _ -> send(test_pid, {:ran, other}) && {:ok, "ran"}
        end,
        "browser" => fn "navigate", _ -> {:ok, "navigated"} end,
        "lookup" => fn _ -> {:ok, "found"} end
      }

      assert {:ok, _, _} = Agent.run(client, base_request(), handlers)
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert [
               %{"tool_use_id" => "c1", "content" => "clicked"},
               %{"tool_use_id" => "c2", "is_error" => true, "content" => "keyboard unavailable"},
               %{"tool_use_id" => "p1", "content" => "found"},
               %{"tool_use_id" => "b1", "content" => "navigated"},
               %{
                 "tool_use_id" => "c3",
                 "is_error" => true,
                 "content" => "Not executed: an earlier computer action in this turn failed.",
                 "toolset_name" => "computer"
               }
             ] = tool_results(second)

      refute_received {:ran, "key"}
    end

    test "the response container is carried to the next request", %{client: client, bypass: bypass} do
      container = %{"id" => "container_01", "expires_at" => "2026-09-26T19:00:00Z"}

      serve(bypass, [
        message([plain("t1", "lookup")], "tool_use", %{"container" => container}),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      assert {:ok, _, _} = Agent.run(client, base_request(), %{"lookup" => fn _ -> {:ok, "x"} end})
      assert_received {:request_body, first}
      assert_received {:request_body, second}

      refute Map.has_key?(first, "container")
      assert second["container"] == "container_01"
    end

    test "pause_turn resumes with the assistant content and no user message", %{
      client: client,
      bypass: bypass
    } do
      paused = [%{"type" => "server_tool_use", "id" => "srv_1", "name" => "advisor", "input" => %{}}]

      serve(bypass, [
        message(paused, "pause_turn"),
        message([%{"type" => "text", "text" => "done"}], "end_turn")
      ])

      assert {:ok, %{stop_reason: :end_turn}, _} = Agent.run(client, base_request(), %{})
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert %{"role" => "assistant", "content" => ^paused} = List.last(second["messages"])
    end

    test "endless pause_turn stops at max_turns (Review Focus 5)", %{client: client, bypass: bypass} do
      paused = message([%{"type" => "text", "text" => "…"}], "pause_turn")
      serve(bypass, List.duplicate(paused, 5))

      assert {:error, :max_turns_exceeded, %{stop_reason: :pause_turn}, _messages} =
               Agent.run(client, base_request(), %{}, max_turns: 2)
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agent_test.exs`
Expected: FAIL — toolset calls are looked up by `name` (the custom `screenshot` handler answers `t1`, no `toolset_name` on results); `Unknown tool: navigate` instead of `Unknown toolset: browser`; no halt text; no `container` in the second body; `pause_turn` returns `{:ok, _, _}` after one call (so `assert_received` for the second body fails) and the max-turns test gets `{:ok, …}`.

- [ ] **Step 3: Implement**

In `lib/claudio/agent.ex`:

1. Types:

```elixir
  @type result :: {:ok, String.t() | [map()]} | {:error, String.t()}
  @type handler :: (map() -> result()) | (String.t(), map() -> result())
  @type handlers :: %{String.t() => handler()}
```

2. Replace `loop/6` with:

```elixir
  defp loop(client, request, handlers, max_turns, on_tool_call, turn) do
    case Messages.create(client, request) do
      {:ok, %Response{stop_reason: reason} = response}
      when reason in [:tool_use, :pause_turn] and turn + 1 >= max_turns ->
        messages =
          extract_messages(request) ++
            [%{"role" => "assistant", "content" => Response.to_assistant_content(response)}]

        {:error, :max_turns_exceeded, response, messages}

      {:ok, %Response{stop_reason: :tool_use} = response} ->
        tool_uses = Tools.extract_tool_uses(response)
        tool_results = execute_tools(tool_uses, handlers, on_tool_call)

        updated_request =
          request
          |> carry_container(response)
          |> Request.add_message(:assistant, Response.to_assistant_content(response))
          # tool_results is a list of tool_result maps — add_message accepts lists as content
          |> Request.add_message(:user, tool_results)

        loop(client, updated_request, handlers, max_turns, on_tool_call, turn + 1)

      {:ok, %Response{stop_reason: :pause_turn} = response} ->
        # A server tool (e.g. the advisor) paused a long turn: resend it unchanged so the
        # API continues it. Counts toward max_turns like a tool round trip.
        updated_request =
          request
          |> carry_container(response)
          |> Request.add_message(:assistant, Response.to_assistant_content(response))

        loop(client, updated_request, handlers, max_turns, on_tool_call, turn + 1)

      {:ok, %Response{} = response} ->
        messages =
          extract_messages(request) ++
            [%{"role" => "assistant", "content" => Response.to_assistant_content(response)}]

        {:ok, response, messages}

      {:error, _} = error ->
        error
    end
  end

  # Programmatic tool calling: continuing needs the container the calls run in.
  defp carry_container(request, %Response{container: %{"id" => id}}),
    do: Request.set_container(request, id)

  defp carry_container(request, %Response{container: %{id: id}}),
    do: Request.set_container(request, id)

  defp carry_container(request, _response), do: request
```

3. Replace `execute_tools/3` with:

```elixir
  # Runs a turn's calls in content order. After a client-toolset call fails, that
  # toolset's later calls in the turn are not run and get the toolset's halt result
  # (computer-use / browser-use "Batch actions"); other tools keep running.
  defp execute_tools(tool_uses, handlers, on_tool_call) do
    {results, _failed_toolsets} =
      Enum.map_reduce(tool_uses, MapSet.new(), fn tool_use, failed ->
        toolset = tool_use.toolset_name

        if toolset && MapSet.member?(failed, toolset) do
          {Tools.halt_result(tool_use), failed}
        else
          result = run_handler(tool_use, handlers)
          if on_tool_call, do: on_tool_call.(tool_use, result)

          {content, is_error} =
            case result do
              {:ok, value} -> {value, false}
              {:error, reason} -> {reason, true}
            end

          failed = if is_error and toolset, do: MapSet.put(failed, toolset), else: failed
          opts = if toolset, do: [toolset_name: toolset], else: []
          {Tools.create_tool_result(tool_use.id, content, is_error, opts), failed}
        end
      end)

    results
  end

  # Dispatch on the (toolset_name, name) pair: a custom tool may share a member's name,
  # and the computer and browser toolsets share names such as "screenshot".
  defp run_handler(%{toolset_name: toolset} = tool_use, handlers) when is_binary(toolset) do
    case Map.get(handlers, toolset) do
      handler when is_function(handler, 2) -> safely(fn -> handler.(tool_use.name, tool_use.input) end)
      nil -> {:error, "Unknown toolset: #{toolset}"}
      _other -> {:error, "Handler for toolset #{toolset} must take (member, input)"}
    end
  end

  defp run_handler(tool_use, handlers) do
    case Map.get(handlers, tool_use.name) do
      handler when is_function(handler, 1) -> safely(fn -> handler.(tool_use.input) end)
      nil -> {:error, "Unknown tool: #{tool_use.name}"}
      _other -> {:error, "Handler for #{tool_use.name} must take (input)"}
    end
  end

  defp safely(fun) do
    fun.()
  catch
    :error, e -> {:error, "Tool error: #{Exception.message(e)}"}
    :throw, value -> {:error, "Tool threw: #{inspect(value)}"}
    :exit, reason -> {:error, "Tool exited: #{inspect(reason)}"}
  end
```

   (`Exception.message/1` of a non-exception `:error` reason: the existing code already calls it on whatever `e` is; keep that behavior — `catch :error, e` normalizes raised exceptions to structs.)

4. Moduledoc — after the handlers example, add:

```
  ## Client toolsets

  Calls from `Request.add_computer_toolset/2` / `add_browser_toolset/2` carry a
  `toolset_name` and go **only** to the handler keyed by it, as `fn member, input -> … end`
  (e.g. `%{"computer" => fn "screenshot", _ -> {:ok, [image_block]} end}`); a plain tool
  with the same name as a member never receives them. Results echo `toolset_name`. If an
  action fails, the toolset's later actions in that turn are not run and are answered
  with the documented halt text (`Claudio.Tools.halt_result/1`).

  ## Programmatic tool calling and pauses

  A response `container` is carried to the next request (required to continue calls made
  from code execution). A `pause_turn` is resumed automatically by resending the
  assistant turn; it counts toward `:max_turns`.
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: PASS, 0 failures — including every existing `run/4` test (unknown tool text, handler error/raise/throw/exit, `on_tool_call`, thinking signature).

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/agent.ex test/agent_test.exs
git commit -m "feat(s14): Agent pair dispatch, toolset batch halt, container carry, pause_turn resume"
```

---
### Task 6: Live integration test

**Files:**
- Create: `test/integration/tool_extensions_integration_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: nothing consumed later.

These repeat probes T1c, T2b, T3d, T4c and run `Agent.run/4` end to end. RED is not observable (written after the code); the unit tests carry the TDD gate. Model behavior (which member it calls, how many programmatic calls) varies, so assertions pin shapes, not counts.

- [ ] **Step 1: Write the integration test**

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ToolExtensionsIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.{Agent, Tools}
  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 300_000

  @model "claude-opus-5-5"

  @weather %{
    "name" => "get_weather",
    "description" => "Get current temperature in C for a city",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }
  }

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "computer toolset: member call → result with toolset_name → reply", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_computer_toolset()
      |> Request.add_message(:user, "Take a screenshot of the screen. Just the screenshot.")
      |> Request.set_max_tokens(512)

    assert {:ok, %Response{stop_reason: :tool_use} = response} = Messages.create(client, request)
    assert [%{toolset_name: "computer"} | _] = tool_uses = Tools.extract_tool_uses(response)

    results =
      Enum.map(tool_uses, fn tu ->
        Tools.create_tool_result(tu.id, "The screen shows an empty desktop.", false,
          toolset_name: tu.toolset_name
        )
      end)

    next =
      request
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, results)

    assert {:ok, %Response{}} = Messages.create(client, next)
  end

  test "tool search finds a deferred tool; the replay is accepted", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_tool_search_tool(:bm25)
      |> Request.add_tool(@weather, defer_loading: true)
      |> Request.add_message(:user, "What's the weather in Paris right now? Use your tools.")
      |> Request.set_max_tokens(1024)

    assert {:ok, %Response{} = response} = Messages.create(client, request)
    assert [%{type: :tool_search_tool_result} | _] =
             Response.get_server_tool_results(response, :tool_search_tool_result)

    results =
      for tu <- Tools.extract_tool_uses(response), do: Tools.create_tool_result(tu.id, "18C, cloudy")

    next =
      request
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, results)

    assert {:ok, %Response{}} = Messages.create(client, next)
  end

  test "programmatic tool calling continues with the container", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_code_execution_tool()
      |> Request.add_tool(@weather, allowed_callers: [:code_execution])
      |> Request.add_message(
        :user,
        "Write Python code that calls get_weather for Paris and London and prints the warmer city. " <>
          "Use code execution to call the tool."
      )
      |> Request.set_max_tokens(2048)

    assert {:ok, %Response{stop_reason: :tool_use, container: %{"id" => id}} = response} =
             Messages.create(client, request)

    assert [%{caller: %{"type" => "code_execution_20260120"}} | _] =
             tool_uses = Tools.extract_tool_uses(response)

    next =
      request
      |> Request.set_container(id)
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, for(tu <- tool_uses, do: Tools.create_tool_result(tu.id, "15")))

    assert {:ok, %Response{}} = Messages.create(client, next)
  end

  @advisor_prompt "Before answering, consult the advisor once about whether 1 is a prime " <>
                    "number. Then answer in one sentence."

  test "advisor blocks replay without the tool; add_message/3 declares the beta", %{client: client} do
    request =
      Request.new("claude-sonnet-5")
      |> Request.add_advisor_tool(@model, max_uses: 1)
      |> Request.add_message(:user, @advisor_prompt)
      |> Request.set_max_tokens(1024)

    assert {:ok, %Response{} = response} = Messages.create(client, request)
    assert [_ | _] = Response.get_server_tool_results(response, :advisor_tool_result)

    # Same first user turn: the reply's thinking block is bound to its prefix. Dropping the
    # advisor tool changes `tools` (also part of the prefix) — accepted on the probe account
    # (T4c, prefix check not enforced there); on an enforced account this replay may need
    # S15's `set_thinking_block_binding(:drop_block)`. Report such a 400 to Q.
    replay =
      Request.new("claude-sonnet-5")
      |> Request.add_message(:user, @advisor_prompt)
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, "Thanks. And 2?")
      |> Request.set_max_tokens(256)

    assert "advisor-tool-2026-03-01" in Request.required_betas(replay)
    assert {:ok, %Response{}} = Messages.create(client, replay)
  end

  test "Agent.run/4: computer toolset handler", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_computer_toolset()
      |> Request.add_message(:user, "Take one screenshot, then reply with the word done.")
      |> Request.set_max_tokens(512)

    handlers = %{"computer" => fn _member, _input -> {:ok, "The screen shows an empty desktop."} end}

    assert {:ok, %Response{}, _messages} = Agent.run(client, request, handlers, max_turns: 4)
  end

  test "Agent.run/4: programmatic calls carry the container", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_code_execution_tool()
      |> Request.add_tool(@weather, allowed_callers: [:code_execution])
      |> Request.add_message(
        :user,
        "Use code execution to call get_weather for Paris and London, then tell me which is warmer."
      )
      |> Request.set_max_tokens(2048)

    handlers = %{"get_weather" => fn %{"city" => city} -> {:ok, if(city == "Paris", do: "18", else: "15")} end}

    assert {:ok, %Response{} = final, _messages} = Agent.run(client, request, handlers, max_turns: 6)
    assert Response.get_text(final) =~ "Paris"
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/integration/tool_extensions_integration_test.exs --include integration`
Expected: 6 tests, 0 failures. If a test fails on model behavior (e.g. no `tool_use` on the first call, or the agent hits `max_turns`), rerun that test once; a second identical failure is reported to Q with the response body — do not loosen assertions silently. A 400 is never model behavior: report it.

- [ ] **Step 3: Commit**

```bash
mix format
git add test/integration/tool_extensions_integration_test.exs
git commit -m "test(s14): live tool search, PTC, advisor, computer toolset and Agent runs"
```

---

### Task 7: Docs and final gates

**Files:**
- Modify: `CHANGELOG.md`, `CLAUDE.md`, `lib/claudio/tools.ex` moduledoc, `docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md`

- [ ] **Step 1: CHANGELOG** (`## [Unreleased] — targets 0.7.0`)

Under `### Fixed`:

```markdown
- `Response.to_assistant_content/1` re-emits `toolset_name` and `caller` on `tool_use` (and
  `caller` on `server_tool_use` / `web_search_tool_result`); replaying a client-toolset call
  without `toolset_name` was rejected.
```

Under `### Changed`:

```markdown
- Parsed `tool_use` blocks gain `caller` and `toolset_name`, `server_tool_use` gains `caller`,
  `web_search_tool_result` gains `caller` and `raw` (`nil` when absent). Code matching the
  whole map with `==` must add them.
- `Claudio.Agent` resumes `pause_turn` (counts toward `:max_turns`) instead of returning it,
  carries the response `container` to the next request, and dispatches client-toolset calls
  to the handler keyed by `toolset_name`. A handler of the wrong arity is now an error result
  instead of a crash.
```

Under `### Added`:

```markdown
- **Tool extensions** (`Claudio.Messages.Request`): `add_tool/3` (`defer_loading:`,
  `allowed_callers:` — `:direct` / `:code_execution` → `"code_execution_20260120"`);
  `add_tool_search_tool/2` (`:regex` / `:bm25`, GA); `add_advisor_tool/3` (declares
  `advisor-tool-2026-03-01`; `add_message/3` declares it for replayed advisor blocks);
  `add_computer_toolset/2` / `add_browser_toolset/2` (`computer_toolset_20260801` /
  `browser_toolset_20260801`, GA); `add_computer_tool/4` `version: :"20251124"`.
- Shallowly typed server-result blocks (`web_fetch_tool_result`, `code_execution_tool_result`,
  `bash_code_execution_tool_result`, `text_editor_code_execution_tool_result`,
  `tool_search_tool_result`, `advisor_tool_result`, `container_upload`; `raw:` replayed
  verbatim), `Response.get_server_tool_results/1,2`, `Response.container` (also from the
  stream).
- `Tools.extract_tool_uses/1` returns `toolset_name` and `caller`; `Tools.create_tool_result/4`
  (`toolset_name:`); `Tools.halt_result/1`.
```

- [ ] **Step 2: CLAUDE.md**

Request Builder — after the `**Server-side tool helpers**` list, add:

```markdown
- **Tool extensions** (`add_tool/3` — `defer_loading:`, `allowed_callers:` (`:code_execution` → `code_execution_20260120`), GA; `add_tool_search_tool/2` — `:regex` / `:bm25`, GA; `add_advisor_tool/3` — declares `advisor-tool-2026-03-01`; `add_computer_toolset/2` / `add_browser_toolset/2` — GA client toolsets, results must echo `toolset_name`; `add_computer_tool/4` `version: :"20251124"` declares `computer-use-2025-11-24`. Opus 5.5 accepts only the computer toolset.)
```

Response Handling — extend the parsed-block list with `web_fetch_tool_result, code_execution_tool_result, bash_code_execution_tool_result, text_editor_code_execution_tool_result, tool_search_tool_result, advisor_tool_result, container_upload`, and add:

```markdown
- **Tool-use round trip** — `tool_use` keeps `caller` / `toolset_name`, `server_tool_use` keeps `caller`, and `to_assistant_content/1` re-emits them; server-result blocks are typed shallowly (`%{type:, tool_use_id:, content: <raw>, caller:, raw:}`, replayed from `raw`); `get_server_tool_results/1,2`; `container` (raw `%{"id", "expires_at"}`)
```

Tools section — add `halt_result/1` and `create_tool_result/4` to the function list. Add an "Agent" note under the Module Organization entry `agent.ex`: `# Stateless tool-calling loop (Claudio.Agent): toolset pair dispatch, container carry, pause_turn resume`.

- [ ] **Step 3: `Claudio.Tools` moduledoc**

Append:

```
  ## Client toolsets

  A call from `Request.add_computer_toolset/2` has a `toolset_name`; answer it with
  `create_tool_result(tool_use.id, result, false, toolset_name: tool_use.toolset_name)`.
  If an action in a batch fails, answer the rest with `halt_result/1`.
```

- [ ] **Step 4: Roadmap** — S14 row status: `implemented on \`feat/s14-tool-extensions\`; spec \`2026-09-26-s14-tool-extensions-design.md\``.

- [ ] **Step 5: Final gates**

Run: `mix format && mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: all pass.

Run: `mix test test/integration/tool_extensions_integration_test.exs --include integration`
Expected: 6 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md CLAUDE.md lib/claudio/tools.ex docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md
git commit -m "docs(s14): CHANGELOG, CLAUDE.md, Tools moduledoc and roadmap for tool extensions"
```

---

## Spec coverage (self-review)

| Spec section | Task |
|---|---|
| §1 `add_tool/3`, tool search, advisor, toolsets, computer version, advisor replay beta | 3 |
| §2 Tools: `extract_tool_uses/1` fields, `create_tool_result/4`, `halt_result/1` | 4 |
| §3 caller/toolset_name round trip, shallow typing, web_search raw, `get_server_tool_results/1,2`, `container` | 1 |
| §4 streaming container | 2 |
| §5 Agent: pair dispatch, halt, container, pause_turn | 5 |
| §6 count_tokens / Batches unchanged | — (no code) |
| Testing — integration 1–5 | 6 |
| Docs | 7 |
