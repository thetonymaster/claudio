defmodule Claudio.Messages.RequestTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Claudio.Messages.Response

  describe "new/1" do
    test "creates a request with model" do
      request = Request.new("claude-3-5-sonnet-20241022")

      assert %Request{model: "claude-3-5-sonnet-20241022", messages: []} = request
    end
  end

  describe "add_message/3" do
    test "adds user message" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:user, "Hello")

      assert [%{"role" => "user", "content" => "Hello"}] = request.messages
    end

    test "adds assistant message" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:assistant, "Hi there")

      assert [%{"role" => "assistant", "content" => "Hi there"}] = request.messages
    end

    test "adds multiple messages in order" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:user, "Hello")
        |> Request.add_message(:assistant, "Hi")
        |> Request.add_message(:user, "How are you?")

      assert length(request.messages) == 3
      assert Enum.at(request.messages, 0)["content"] == "Hello"
      assert Enum.at(request.messages, 1)["content"] == "Hi"
      assert Enum.at(request.messages, 2)["content"] == "How are you?"
    end
  end

  describe "add_messages/2" do
    # Every content shape add_message/3 treats specially, in one conversation.
    @conversation [
      {:user, "What is the weather?"},
      {:assistant,
       [
         %{"type" => "fallback", "from" => %{"model" => "a"}, "to" => %{"model" => "b"}},
         %{"type" => "text", "text" => "Checking."}
       ]},
      {:user, [%{"type" => "text", "text" => "go on"}]},
      {:assistant, [%{"type" => "compaction", "content" => "s", "signature" => "sig"}]},
      {:assistant, [%{"type" => "compaction", "content" => "s"}]},
      {:assistant, [%{type: :server_tool_use, id: "s", name: "advisor", input: %{}}]},
      {:assistant,
       [%{"type" => "mcp_tool_use", "id" => "m", "name" => "x", "server_name" => "s"}]},
      {:user, [%{type: :text, text: "typed", citations: nil}]}
    ]

    defp one_by_one(request, messages),
      do:
        Enum.reduce(messages, request, fn {role, content}, acc ->
          Request.add_message(acc, role, content)
        end)

    test "equals add_message/3 once per message: messages, order and betas" do
      base =
        Request.new("m")
        |> Request.add_message(:user, "earlier")
        |> Request.add_beta("context-management-2025-06-27")

      assert Request.add_messages(base, @conversation) == one_by_one(base, @conversation)

      assert Request.required_betas(Request.add_messages(base, @conversation)) == [
               "context-management-2025-06-27",
               "server-side-fallback-2026-07-01",
               "compact-2026-09-04",
               "compact-2026-01-12",
               "advisor-tool-2026-03-01",
               "mcp-client-2025-11-20"
             ]
    end

    test "an empty list leaves the request as it is" do
      request = Request.add_message(Request.new("m"), :user, "hi")
      assert Request.add_messages(request, []) == request
    end

    test "raises as add_message/3 does, naming add_messages/2" do
      request = Request.new("m")

      assert_raise ArgumentError,
                   "Request.add_messages/2: content must be a string or a list of content blocks; got nil",
                   fn -> Request.add_messages(request, [{:user, "ok"}, {:assistant, nil}]) end

      assert_raise ArgumentError,
                   "Request.add_messages/2: :system is not a message role. Use set_system/2 for " <>
                     "the system prompt, or add_system_message/3 for a mid-conversation system message",
                   fn -> Request.add_messages(request, [{:system, "be terse"}]) end

      assert_raise ArgumentError,
                   ~s|Request.add_messages/2: role must be :user or :assistant; got "user"|,
                   fn -> Request.add_messages(request, [{"user", "hi"}]) end

      assert_raise ArgumentError,
                   "Request.add_messages/2: each message must be a {role, content} tuple",
                   fn -> Request.add_messages(request, [%{role: :user, content: "hi"}]) end
    end

    test "add_message/3 keeps its own name in its errors" do
      assert_raise ArgumentError,
                   "Request.add_message/3: content must be a string or a list of content blocks; got nil",
                   fn -> Request.add_message(Request.new("m"), :user, nil) end
    end
  end

  describe "add_message/3 with a fallback block" do
    test "declares the fallback beta (the API rejects a replayed fallback block without it)" do
      for block <- [
            %{"type" => "fallback", "from" => %{"model" => "a"}, "to" => %{"model" => "b"}},
            %{type: "fallback"},
            %{type: :fallback}
          ] do
        request =
          Request.new("m")
          |> Request.add_message(:assistant, [block, %{"type" => "text", "text" => "hi"}])

        assert Request.required_betas(request) == ["server-side-fallback-2026-07-01"]
      end
    end

    test "content without a fallback block declares nothing" do
      for content <- ["hi", [%{"type" => "text", "text" => "hi"}], ["stray"]] do
        request = Request.new("m") |> Request.add_message(:user, content)
        assert Request.required_betas(request) == []
      end
    end
  end

  describe "add_message/3 with a compaction block" do
    test "a signed block declares compact-2026-09-04" do
      for block <- [
            %{"type" => "compaction", "content" => "s", "signature" => "sig"},
            %{type: "compaction", content: "s", signature: "sig"},
            %{
              type: :compaction,
              content: "s",
              raw: %{"type" => "compaction", "signature" => "sig"}
            }
          ] do
        request = Request.new("m") |> Request.add_message(:assistant, [block])
        assert Request.required_betas(request) == ["compact-2026-09-04"]
      end
    end

    test "an unsigned block declares compact-2026-01-12" do
      for block <- [
            %{"type" => "compaction", "content" => "s"},
            %{type: :compaction, content: "s", raw: %{"type" => "compaction", "content" => "s"}}
          ] do
        request = Request.new("m") |> Request.add_message(:assistant, [block])
        assert Request.required_betas(request) == ["compact-2026-01-12"]
      end
    end

    test "content without a compaction block declares nothing (Review Focus 4)" do
      for content <- ["hi", [%{"type" => "text", "text" => "hi"}], ["stray", 42]] do
        request = Request.new("m") |> Request.add_message(:user, content)
        assert Request.required_betas(request) == []
      end
    end
  end

  describe "add_message/3 with typed blocks (S13 review)" do
    test "a typed block carrying raw is sent as its original map" do
      raw = %{"type" => "compaction", "content" => "s", "signature" => "sig"}

      typed =
        Response.compaction_block(Response.from_map(%{"content" => [raw]}))

      request = Request.new("m") |> Request.add_message(:assistant, [typed])

      assert request.messages == [%{"role" => "assistant", "content" => [raw]}]
      assert Request.required_betas(request) == ["compact-2026-09-04"]
    end
  end

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

      assert Request.required_betas(Request.add_message(Request.new("m"), :assistant, [block])) ==
               []
    end
  end

  describe "add_message/3 with MCP blocks" do
    # Live probe 2026-10-05: replaying mcp_tool_use without the beta is a 400
    # ("Input tag 'mcp_tool_use' ... does not match any of the expected tags").
    test "an mcp_tool_use or mcp_tool_result block declares the MCP connector beta" do
      for block <- [
            %{"type" => "mcp_tool_use", "id" => "m", "name" => "x", "server_name" => "s"},
            %{"type" => "mcp_tool_result", "tool_use_id" => "m", "content" => []},
            %{type: :mcp_tool_use, id: "m", name: "x", server_name: "s", input: %{}},
            %{type: :mcp_tool_result, tool_use_id: "m", content: [], is_error: false}
          ] do
        request = Request.new("m") |> Request.add_message(:assistant, [block])
        assert Request.required_betas(request) == ["mcp-client-2025-11-20"]
      end
    end

    test "is declared once alongside add_mcp_server/2" do
      block = %{"type" => "mcp_tool_use", "id" => "m", "name" => "x", "server_name" => "s"}

      request =
        Request.new("m")
        |> Request.add_mcp_server(%{"type" => "url", "url" => "https://x", "name" => "s"})
        |> Request.add_message(:assistant, [block])

      assert Request.required_betas(request) == ["mcp-client-2025-11-20"]
    end
  end

  describe "set_system/2" do
    test "sets system prompt" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_system("You are a helpful assistant")

      assert request.system == "You are a helpful assistant"
    end
  end

  describe "set_system_with_cache/2" do
    test "wraps text in a system text block with default ephemeral cache_control" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_system_with_cache("Long context")

      assert request.system == [
               %{
                 "type" => "text",
                 "text" => "Long context",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]
    end

    test "honours an explicit ttl" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_system_with_cache("Long context", ttl: "1h")

      assert request.system == [
               %{
                 "type" => "text",
                 "text" => "Long context",
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               }
             ]
    end
  end

  describe "set_max_tokens/2" do
    test "sets max tokens" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_max_tokens(1024)

      assert request.max_tokens == 1024
    end
  end

  describe "set_temperature/2" do
    test "sets temperature" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_temperature(0.7)

      assert request.temperature == 0.7
    end
  end

  describe "set_top_p/2" do
    test "sets top_p" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_top_p(0.9)

      assert request.top_p == 0.9
    end
  end

  describe "set_top_k/2" do
    test "sets top_k" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_top_k(40)

      assert request.top_k == 40
    end
  end

  describe "set_stop_sequences/2" do
    test "sets stop sequences" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_stop_sequences(["END", "STOP"])

      assert request.stop_sequences == ["END", "STOP"]
    end
  end

  describe "enable_streaming/1" do
    test "enables streaming" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.enable_streaming()

      assert request.stream == true
    end
  end

  describe "add_tool/2" do
    test "adds a tool" do
      tool = %{
        "name" => "get_weather",
        "description" => "Get weather",
        "input_schema" => %{"type" => "object"}
      }

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool(tool)

      assert request.tools == [tool]
    end

    test "adds multiple tools" do
      tool1 = %{"name" => "tool1"}
      tool2 = %{"name" => "tool2"}

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool(tool1)
        |> Request.add_tool(tool2)

      assert request.tools == [tool1, tool2]
    end
  end

  describe "add_tool_with_cache/3" do
    test "appends a tool with default ephemeral cache_control" do
      tool = %{"name" => "get_weather", "input_schema" => %{"type" => "object"}}

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool_with_cache(tool)

      assert request.tools == [Map.put(tool, "cache_control", %{"type" => "ephemeral"})]
    end

    test "honours an explicit ttl" do
      tool = %{"name" => "get_weather", "input_schema" => %{"type" => "object"}}

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool_with_cache(tool, ttl: "1h")

      assert request.tools ==
               [Map.put(tool, "cache_control", %{"type" => "ephemeral", "ttl" => "1h"})]
    end
  end

  describe "set_tool_choice/2" do
    test "sets tool choice to auto" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_tool_choice(:auto)

      assert request.tool_choice == %{"type" => "auto"}
    end

    test "sets tool choice to any" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_tool_choice(:any)

      assert request.tool_choice == %{"type" => "any"}
    end

    test "sets tool choice to specific tool" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_tool_choice({:tool, "get_weather"})

      assert request.tool_choice == %{"type" => "tool", "name" => "get_weather"}
    end
  end

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

    test "a raw compact_20260112 edit also declares compact-2026-01-12" do
      for config <- [
            %{"edits" => [%{"type" => "compact_20260112"}]},
            %{edits: [%{type: "compact_20260112"}]}
          ] do
        request = Request.new("claude-opus-5-5") |> Request.set_context_management(config)

        assert Request.required_betas(request) == [
                 "context-management-2025-06-27",
                 "compact-2026-01-12"
               ]
      end
    end

    test "without a compact edit only the context-management beta is declared" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      assert Request.required_betas(request) == ["context-management-2025-06-27"]
    end
  end

  describe "context-editing builders" do
    defp edits(request), do: Request.to_map(request)["context_management"]["edits"]

    test "add_clear_tool_uses/2 with no options sends only the type" do
      request = Request.new("claude-opus-5-5") |> Request.add_clear_tool_uses()

      assert edits(request) == [%{"type" => "clear_tool_uses_20250919"}]
      assert Request.required_betas(request) == ["context-management-2025-06-27"]
    end

    test "add_clear_tool_uses/2 maps every option" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_clear_tool_uses(
          trigger: {:tool_uses, 5},
          keep: 2,
          clear_at_least: 1000,
          exclude_tools: ["web_search"],
          clear_tool_inputs: false
        )

      assert edits(request) == [
               %{
                 "type" => "clear_tool_uses_20250919",
                 "trigger" => %{"type" => "tool_uses", "value" => 5},
                 "keep" => %{"type" => "tool_uses", "value" => 2},
                 "clear_at_least" => %{"type" => "input_tokens", "value" => 1000},
                 "exclude_tools" => ["web_search"],
                 "clear_tool_inputs" => false
               }
             ]
    end

    test "add_clear_tool_uses/2 input_tokens trigger" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_clear_tool_uses(trigger: {:input_tokens, 100_000})

      assert [%{"trigger" => %{"type" => "input_tokens", "value" => 100_000}}] = edits(request)
    end

    test "add_clear_thinking/2 maps keep: :all and keep: n" do
      assert edits(Request.new("m") |> Request.add_clear_thinking(keep: :all)) ==
               [%{"type" => "clear_thinking_20251015", "keep" => "all"}]

      assert edits(Request.new("m") |> Request.add_clear_thinking(keep: 2)) ==
               [
                 %{
                   "type" => "clear_thinking_20251015",
                   "keep" => %{"type" => "thinking_turns", "value" => 2}
                 }
               ]

      assert edits(Request.new("m") |> Request.add_clear_thinking()) ==
               [%{"type" => "clear_thinking_20251015"}]
    end

    test "add_compaction/2 with no options sends only the type" do
      assert edits(Request.new("m") |> Request.add_compaction()) == [
               %{"type" => "compact_20260112"}
             ]
    end

    test "add_compaction/2 maps its options and declares compact-2026-01-12" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_compaction(
          trigger: 150_000,
          pause_after_compaction: true,
          instructions: "Keep file paths."
        )

      assert edits(request) == [
               %{
                 "type" => "compact_20260112",
                 "trigger" => %{"type" => "input_tokens", "value" => 150_000},
                 "pause_after_compaction" => true,
                 "instructions" => "Keep file paths."
               }
             ]

      assert Request.required_betas(request) == ["compact-2026-01-12"]
    end

    test "clear_thinking is placed first whatever the call order; others keep their order" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_clear_tool_uses()
        |> Request.add_compaction()
        |> Request.add_clear_thinking(keep: :all)

      assert Enum.map(edits(request), & &1["type"]) ==
               ["clear_thinking_20251015", "clear_tool_uses_20250919", "compact_20260112"]

      assert Request.required_betas(request) == [
               "context-management-2025-06-27",
               "compact-2026-01-12"
             ]
    end

    test "builders keep other keys a raw set_context_management/2 put there" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_context_management(%{"edits" => [], "future_key" => 1})
        |> Request.add_clear_tool_uses()

      assert Request.to_map(request)["context_management"] == %{
               "edits" => [%{"type" => "clear_tool_uses_20250919"}],
               "future_key" => 1
             }
    end

    test "an atom-keyed raw config keeps a single :edits key" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_context_management(%{edits: [%{type: "clear_tool_uses_20250919"}]})
        |> Request.add_compaction()

      cm = Request.to_map(request)["context_management"]

      refute Map.has_key?(cm, "edits")
      assert [%{type: "clear_tool_uses_20250919"}, %{"type" => "compact_20260112"}] = cm.edits
    end

    test "set_context_management/2 after builders replaces the edits; betas stay" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_compaction()
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      assert edits(request) == [%{"type" => "clear_tool_uses_20250919"}]
      assert "compact-2026-01-12" in Request.required_betas(request)
    end

    test "invalid shapes raise ArgumentError" do
      r = Request.new("claude-opus-5-5")

      assert_raise ArgumentError, ~r/add_clear_tool_uses\/2 :trigger/, fn ->
        Request.add_clear_tool_uses(r, trigger: {:turns, 3})
      end

      assert_raise ArgumentError, ~r/add_clear_tool_uses\/2 :keep/, fn ->
        Request.add_clear_tool_uses(r, keep: "3")
      end

      assert_raise ArgumentError, ~r/add_clear_thinking\/2 :keep/, fn ->
        Request.add_clear_thinking(r, keep: 0)
      end

      assert_raise ArgumentError, ~r/add_compaction\/2 :trigger/, fn ->
        Request.add_compaction(r, trigger: {:input_tokens, 50_000})
      end

      assert_raise ArgumentError, fn -> Request.add_compaction(r, bogus: 1) end

      assert_raise ArgumentError, ~r/add_compaction\/2 :pause_after_compaction/, fn ->
        Request.add_compaction(r, pause_after_compaction: "yes")
      end

      # false is not "absent": it must be rejected, not sent.
      assert_raise ArgumentError, ~r/add_clear_tool_uses\/2 :keep/, fn ->
        Request.add_clear_tool_uses(r, keep: false)
      end

      assert_raise ArgumentError, ~r/add_compaction\/2 :trigger/, fn ->
        Request.add_compaction(r, trigger: false)
      end
    end
  end

  describe "request_compaction/2" do
    test "sets compaction: summarize and declares compact-2026-09-04" do
      request = Request.new("claude-opus-5-5") |> Request.request_compaction()

      assert Request.to_map(request)["compaction"] == %{"type" => "summarize"}
      assert Request.required_betas(request) == ["compact-2026-09-04"]
    end

    test "instructions are passed through" do
      request =
        Request.new("claude-opus-5-5") |> Request.request_compaction(instructions: "Keep paths.")

      assert Request.to_map(request)["compaction"] == %{
               "type" => "summarize",
               "instructions" => "Keep paths."
             }
    end

    test "unset: to_map/1 has no compaction key" do
      refute Map.has_key?(Request.to_map(Request.new("m")), "compaction")
    end

    test "unknown options raise" do
      assert_raise ArgumentError, fn -> Request.request_compaction(Request.new("m"), foo: 1) end
    end
  end

  describe "apply_compaction/2" do
    @signed %{"type" => "compaction", "content" => "Summary.", "signature" => "sig"}

    test "on-demand: history becomes one assistant message holding the block; compaction cleared" do
      summary = Response.from_map(%{"stop_reason" => "compaction", "content" => [@signed]})

      request =
        Request.new("claude-opus-5-5")
        |> Request.add_message(:user, "a")
        |> Request.add_message(:assistant, "b")
        |> Request.request_compaction()
        |> Request.apply_compaction(summary)

      assert request.messages == [%{"role" => "assistant", "content" => [@signed]}]
      assert request.compaction == nil
      refute Map.has_key?(Request.to_map(request), "compaction")
      assert "compact-2026-09-04" in Request.required_betas(request)
    end

    test "threshold: keeps content from the block onward, keeps context_management" do
      thinking = %{"type" => "thinking", "thinking" => "", "signature" => "tsig"}
      text = %{"type" => "text", "text" => "Answer"}
      block = %{"type" => "compaction", "content" => "Summary."}

      response =
        Response.from_map(%{"stop_reason" => "end_turn", "content" => [block, thinking, text]})

      request =
        Request.new("claude-opus-5-5")
        |> Request.add_compaction(trigger: 50_000)
        |> Request.add_message(:user, "long history")
        |> Request.apply_compaction(response)

      assert request.messages == [%{"role" => "assistant", "content" => [block, thinking, text]}]

      assert Request.to_map(request)["context_management"] == %{
               "edits" => [
                 %{
                   "type" => "compact_20260112",
                   "trigger" => %{"type" => "input_tokens", "value" => 50_000}
                 }
               ]
             }

      assert Request.required_betas(request) == ["compact-2026-01-12"]
    end

    test "two compaction blocks: content from the last one" do
      first = %{"type" => "compaction", "content" => "old"}
      last = %{"type" => "compaction", "content" => "new"}

      response =
        Response.from_map(%{"content" => [first, %{"type" => "text", "text" => "x"}, last]})

      request = Request.new("m") |> Request.apply_compaction(response)

      assert request.messages == [%{"role" => "assistant", "content" => [last]}]
    end

    test "keeps system, tools, thinking, max_tokens and betas (Review Focus 1)" do
      summary = Response.from_map(%{"stop_reason" => "compaction", "content" => [@signed]})
      tool = %{"name" => "t", "description" => "d", "input_schema" => %{"type" => "object"}}

      before =
        Request.new("claude-opus-5-5")
        |> Request.set_system("sys")
        |> Request.add_tool(tool)
        |> Request.enable_adaptive_thinking()
        |> Request.set_max_tokens(512)
        |> Request.add_beta("x-2026-01-01")
        |> Request.add_message(:user, "a")

      after_ = Request.apply_compaction(before, summary)

      assert after_.system == "sys"
      assert after_.tools == [tool]
      assert after_.thinking == %{"type" => "adaptive"}
      assert after_.max_tokens == 512
      assert Request.required_betas(after_) == ["x-2026-01-01", "compact-2026-09-04"]
    end

    test "a failed compaction (content: nil) raises instead of erasing the history" do
      response =
        Response.from_map(%{
          "stop_reason" => "compaction",
          "content" => [%{"type" => "compaction", "content" => nil}]
        })

      assert_raise ArgumentError, ~r/apply_compaction\/2 .*compaction failed/, fn ->
        Request.new("m")
        |> Request.add_message(:user, "important long history")
        |> Request.apply_compaction(response)
      end
    end

    test "a response without a compaction block raises" do
      response =
        Response.from_map(%{
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "x"}]
        })

      assert_raise ArgumentError, ~r/apply_compaction\/2 .*no compaction block.*:end_turn/, fn ->
        Request.apply_compaction(Request.new("m"), response)
      end
    end
  end

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

  describe "to_map/1" do
    test "converts request to map with only required fields" do
      request = Request.new("claude-3-5-sonnet-20241022")

      map = Request.to_map(request)

      assert map["model"] == "claude-3-5-sonnet-20241022"
      assert map["messages"] == []
      refute Map.has_key?(map, "system")
      refute Map.has_key?(map, "max_tokens")
    end

    test "includes optional fields when set" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:user, "Hello")
        |> Request.set_max_tokens(1024)
        |> Request.set_temperature(0.7)
        |> Request.set_system("Be helpful")

      map = Request.to_map(request)

      assert map["model"] == "claude-3-5-sonnet-20241022"
      assert map["max_tokens"] == 1024
      assert map["temperature"] == 0.7
      assert map["system"] == "Be helpful"
      assert length(map["messages"]) == 1
    end
  end

  describe "add_message_with_document/5" do
    test "no opts emits the original document block (backward compatible)" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123")

      [message] = Request.to_map(request)["messages"]

      assert message["content"] == [
               %{
                 "type" => "document",
                 "source" => %{"type" => "file", "file_id" => "file_abc123"}
               },
               %{"type" => "text", "text" => "Summarize"}
             ]
    end

    test "citations: true enables citations on the document block" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123", citations: true)

      [message] = Request.to_map(request)["messages"]
      [document, _text] = message["content"]
      assert document["citations"] == %{"enabled" => true}
    end

    test ":title and :context are threaded onto the document block" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123",
          title: "Q4 Report",
          context: "Internal financials"
        )

      [message] = Request.to_map(request)["messages"]
      [document, _text] = message["content"]
      assert document["title"] == "Q4 Report"
      assert document["context"] == "Internal financials"
    end

    test "citations: false omits the citations key" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123", citations: false)

      [message] = Request.to_map(request)["messages"]
      [document, _text] = message["content"]
      refute Map.has_key?(document, "citations")
    end
  end

  describe "search_result_block/4" do
    test "wraps string contents into text blocks with required fields" do
      block =
        Request.search_result_block("https://example.com/a", "Article Title", [
          "chunk one",
          "chunk two"
        ])

      assert block == %{
               "type" => "search_result",
               "source" => "https://example.com/a",
               "title" => "Article Title",
               "content" => [
                 %{"type" => "text", "text" => "chunk one"},
                 %{"type" => "text", "text" => "chunk two"}
               ]
             }
    end

    test "passes pre-built text-block maps through unchanged" do
      content = [%{"type" => "text", "text" => "already a block"}]
      block = Request.search_result_block("src", "Title", content)
      assert block["content"] == content
    end

    test "citations: true enables citations" do
      block = Request.search_result_block("src", "Title", ["x"], citations: true)
      assert block["citations"] == %{"enabled" => true}
    end

    test "citations: false omits the citations key" do
      block = Request.search_result_block("src", "Title", ["x"], citations: false)
      refute Map.has_key?(block, "citations")
    end

    test "cache_control: true adds default ephemeral cache_control" do
      block = Request.search_result_block("src", "Title", ["x"], cache_control: true)
      assert block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "cache_control with a ttl string sets the ttl" do
      block = Request.search_result_block("src", "Title", ["x"], cache_control: "1h")
      assert block["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
    end

    test "composes into a message via add_message/3" do
      result = Request.search_result_block("src", "Title", ["x"], citations: true)

      request =
        Request.new("claude-opus-4-8")
        |> Request.add_message(:user, [result, %{"type" => "text", "text" => "Question?"}])

      [message] = Request.to_map(request)["messages"]
      assert [%{"type" => "search_result"}, %{"type" => "text"}] = message["content"]
    end
  end

  describe "add_web_search_tool/2 (S6)" do
    test "default emits web_search_20260209 with no beta" do
      request = Request.new("claude-opus-4-8") |> Request.add_web_search_tool()

      assert Request.to_map(request)["tools"] == [
               %{"type" => "web_search_20260209", "name" => "web_search"}
             ]

      assert Request.required_betas(request) == []
    end

    test "version: :basic selects web_search_20250305" do
      request = Request.new("claude-opus-4-8") |> Request.add_web_search_tool(version: :basic)
      [tool] = Request.to_map(request)["tools"]
      assert tool["type"] == "web_search_20250305"
    end

    test "threads max_uses / allowed_domains / blocked_domains / user_location" do
      request =
        Request.new("claude-opus-4-8")
        |> Request.add_web_search_tool(
          max_uses: 3,
          allowed_domains: ["example.com"],
          blocked_domains: ["spam.com"],
          user_location: %{"type" => "approximate", "country" => "US"}
        )

      [tool] = Request.to_map(request)["tools"]
      assert tool["max_uses"] == 3
      assert tool["allowed_domains"] == ["example.com"]
      assert tool["blocked_domains"] == ["spam.com"]
      assert tool["user_location"] == %{"type" => "approximate", "country" => "US"}
    end

    test "appends after an existing tool" do
      request =
        Request.new("claude-opus-4-8")
        |> Request.add_tool(%{"name" => "x", "input_schema" => %{"type" => "object"}})
        |> Request.add_web_search_tool()

      assert length(Request.to_map(request)["tools"]) == 2
    end
  end

  describe "web tool response_inclusion / allowed_callers (B5)" do
    test "web search passes response_inclusion and allowed_callers through" do
      r =
        Request.new("m")
        |> Request.add_web_search_tool(
          version: :"20260318",
          response_inclusion: "excluded",
          allowed_callers: [:direct]
        )

      [tool] = Request.to_map(r)["tools"]
      assert tool["type"] == "web_search_20260318"
      assert tool["response_inclusion"] == "excluded"
      assert tool["allowed_callers"] == ["direct"]
    end

    test "web fetch passes response_inclusion and allowed_callers through" do
      r =
        Request.new("m")
        |> Request.add_web_fetch_tool(
          version: :"20260318",
          response_inclusion: "excluded",
          allowed_callers: [:direct]
        )

      [tool] = Request.to_map(r)["tools"]
      assert tool["type"] == "web_fetch_20260318"
      assert tool["response_inclusion"] == "excluded"
      assert tool["allowed_callers"] == ["direct"]
    end
  end

  describe "add_web_fetch_tool/2 (S6)" do
    test "default emits web_fetch_20260209 with no beta" do
      request = Request.new("claude-opus-4-8") |> Request.add_web_fetch_tool()

      assert Request.to_map(request)["tools"] == [
               %{"type" => "web_fetch_20260209", "name" => "web_fetch"}
             ]

      assert Request.required_betas(request) == []
    end

    test "version: :basic selects web_fetch_20250910" do
      request = Request.new("claude-opus-4-8") |> Request.add_web_fetch_tool(version: :basic)
      [tool] = Request.to_map(request)["tools"]
      assert tool["type"] == "web_fetch_20250910"
    end

    test "citations: true and content/domain opts are threaded" do
      request =
        Request.new("claude-opus-4-8")
        |> Request.add_web_fetch_tool(
          citations: true,
          max_uses: 5,
          allowed_domains: ["example.com"],
          blocked_domains: ["spam.com"],
          max_content_tokens: 50_000
        )

      [tool] = Request.to_map(request)["tools"]
      assert tool["citations"] == %{"enabled" => true}
      assert tool["max_uses"] == 5
      assert tool["allowed_domains"] == ["example.com"]
      assert tool["blocked_domains"] == ["spam.com"]
      assert tool["max_content_tokens"] == 50_000
    end

    test "citations: false omits the citations key" do
      request = Request.new("claude-opus-4-8") |> Request.add_web_fetch_tool(citations: false)
      [tool] = Request.to_map(request)["tools"]
      refute Map.has_key?(tool, "citations")
    end
  end

  describe "code execution / bash / text editor (S6)" do
    test "add_code_execution_tool defaults to code_execution_20260521 with no beta" do
      request = Request.new("claude-opus-5") |> Request.add_code_execution_tool()

      assert Request.to_map(request)["tools"] == [
               %{"type" => "code_execution_20260521", "name" => "code_execution"}
             ]

      assert Request.required_betas(request) == []
    end

    test "add_code_execution_tool :version selects older versions" do
      for {version, type} <- [
            {:"20260120", "code_execution_20260120"},
            {:"20250825", "code_execution_20250825"}
          ] do
        [tool] =
          Request.new("claude-opus-5")
          |> Request.add_code_execution_tool(version: version)
          |> Request.to_map()
          |> Map.fetch!("tools")

        assert tool == %{"type" => type, "name" => "code_execution"}
      end
    end

    test "add_code_execution_tool rejects an unknown version" do
      assert_raise ArgumentError, ~r/:version must be one of/, fn ->
        Request.new("claude-opus-5") |> Request.add_code_execution_tool(version: :"20250522")
      end
    end

    test "add_bash_tool emits the schema-less bash tool" do
      request = Request.new("claude-opus-4-8") |> Request.add_bash_tool()

      assert Request.to_map(request)["tools"] == [
               %{"type" => "bash_20250124", "name" => "bash"}
             ]
    end

    test "add_text_editor_tool emits str_replace_based_edit_tool" do
      request = Request.new("claude-opus-4-8") |> Request.add_text_editor_tool()

      assert Request.to_map(request)["tools"] == [
               %{"type" => "text_editor_20250728", "name" => "str_replace_based_edit_tool"}
             ]
    end

    test "add_text_editor_tool threads :max_characters" do
      request =
        Request.new("claude-opus-4-8") |> Request.add_text_editor_tool(max_characters: 10_000)

      [tool] = Request.to_map(request)["tools"]
      assert tool["max_characters"] == 10_000
    end
  end

  describe "add_memory_tool/1 (S6)" do
    test "emits memory_20250818 with no beta" do
      request = Request.new("claude-opus-4-8") |> Request.add_memory_tool()

      assert Request.to_map(request)["tools"] == [
               %{"type" => "memory_20250818", "name" => "memory"}
             ]

      assert Request.required_betas(request) == []
    end
  end

  describe "add_computer_tool/4 (S6)" do
    test "emits computer_20250124 with display dims and declares the beta" do
      request = Request.new("claude-opus-4-8") |> Request.add_computer_tool(1280, 800)

      assert Request.to_map(request)["tools"] == [
               %{
                 "type" => "computer_20250124",
                 "name" => "computer",
                 "display_width_px" => 1280,
                 "display_height_px" => 800
               }
             ]

      assert "computer-use-2025-01-24" in Request.required_betas(request)
    end

    test "threads :display_number" do
      request =
        Request.new("claude-opus-4-8") |> Request.add_computer_tool(1280, 800, display_number: 1)

      [tool] = Request.to_map(request)["tools"]
      assert tool["display_number"] == 1
    end

    test "version: :\"20251124\" emits computer_20251124 with its beta" do
      request =
        Request.new("claude-opus-4-8")
        |> Request.add_computer_tool(1280, 800, version: :"20251124")

      assert [%{"type" => "computer_20251124", "name" => "computer"}] =
               Request.to_map(request)["tools"]

      assert Request.required_betas(request) == ["computer-use-2025-11-24"]
    end

    test "an unknown version or option raises; the default may be passed explicitly" do
      assert_raise ArgumentError, ~r/add_computer_tool\/4 :version/, fn ->
        Request.add_computer_tool(Request.new("m"), 1, 1, version: :"20260801")
      end

      assert_raise ArgumentError, fn ->
        Request.add_computer_tool(Request.new("m"), 1, 1, versoin: 1)
      end

      assert [%{"type" => "computer_20250124"}] =
               Request.to_map(
                 Request.add_computer_tool(Request.new("m"), 1, 1, version: :"20250124")
               )["tools"]
    end
  end

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
                 "allowed_callers" => [
                   "direct",
                   "code_execution_20260120",
                   "code_execution_20260521"
                 ]
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
        |> Request.add_advisor_tool("claude-opus-5-5",
          max_uses: 3,
          max_tokens: 2048,
          caching: "1h"
        )

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

      assert_raise ArgumentError, fn ->
        Request.add_advisor_tool(Request.new("m"), "x", foo: 1)
      end
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
          configs: %{"zoom" => %{"defer_loading" => false}, javascript_exec: %{enabled: true}},
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

    test "member configs may be keyword lists; other shapes raise naming :configs" do
      request =
        Request.new("m") |> Request.add_computer_toolset(configs: %{zoom: [enabled: false]})

      assert [%{"configs" => %{"zoom" => %{"enabled" => false}}}] =
               Request.to_map(request)["tools"]

      assert_raise ArgumentError, ~r/add_computer_toolset\/2 :configs/, fn ->
        Request.add_computer_toolset(Request.new("m"), configs: %{zoom: :off})
      end
    end

    test "unknown options raise" do
      assert_raise ArgumentError, fn ->
        Request.add_computer_toolset(Request.new("m"), name: "x")
      end
    end
  end

  describe "enable_adaptive_thinking/2" do
    test "no opts emits type adaptive only, no betas" do
      request = Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == []
    end

    test "each display value is emitted as a string" do
      for display <- [:summarized, :omitted, :updates] do
        request =
          Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(display: display)

        assert Request.to_map(request)["thinking"] == %{
                 "type" => "adaptive",
                 "display" => Atom.to_string(display)
               }
      end
    end

    test "only display: :updates declares the updates beta, once" do
      updates =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :updates)
        |> Request.enable_adaptive_thinking(display: :updates)

      assert Request.required_betas(updates) == ["thinking-display-updates-2026-08-18"]

      omitted =
        Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(display: :omitted)

      assert Request.required_betas(omitted) == []
    end

    test "re-calling without display replaces thinking; the beta stays declared" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :updates)
        |> Request.enable_adaptive_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == ["thinking-display-updates-2026-08-18"]
    end

    test "unknown display values raise" do
      for bad <- [:full, "omitted"] do
        assert_raise ArgumentError,
                     ~r/enable_adaptive_thinking\/2 :display must be one of :summarized, :omitted, :updates; got/,
                     fn ->
                       Request.new("claude-opus-5-5")
                       |> Request.enable_adaptive_thinking(display: bad)
                     end
      end
    end

    test "display: nil means the model default (supports display: opts[:display] passthrough)" do
      request = Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(display: nil)

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == []
    end

    test "unknown option keys raise" do
      assert_raise ArgumentError, fn ->
        Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(budget_tokens: 1024)
      end
    end

    test "block_binding: puts prefix_mismatch_behavior in thinking and declares the beta" do
      for behavior <- [:error, :drop_block] do
        request =
          Request.new("claude-opus-5-5")
          |> Request.enable_adaptive_thinking(block_binding: behavior)

        assert Request.to_map(request)["thinking"] == %{
                 "type" => "adaptive",
                 "block_binding" => %{"prefix_mismatch_behavior" => Atom.to_string(behavior)}
               }

        assert Request.required_betas(request) == ["thinking-binding-controls-2026-08-01"]
      end
    end

    test "block_binding composes with display: :summarized (spec Testing)" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :summarized, block_binding: :drop_block)

      assert Request.to_map(request)["thinking"] == %{
               "type" => "adaptive",
               "display" => "summarized",
               "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
             }

      assert Request.required_betas(request) == ["thinking-binding-controls-2026-08-01"]
    end

    test "block_binding composes with display: :updates — both betas (Review Focus 2)" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :updates, block_binding: :drop_block)

      assert Request.to_map(request)["thinking"] == %{
               "type" => "adaptive",
               "display" => "updates",
               "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
             }

      assert Request.required_betas(request) == [
               "thinking-display-updates-2026-08-18",
               "thinking-binding-controls-2026-08-01"
             ]
    end

    test "re-calling without block_binding drops it; the beta stays (Review Focus 3)" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(block_binding: :error)
        |> Request.enable_adaptive_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == ["thinking-binding-controls-2026-08-01"]
    end

    test "block_binding: nil is the same as omitting it" do
      request = Request.new("m") |> Request.enable_adaptive_thinking(block_binding: nil)

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == []
    end

    test "unknown block_binding values raise" do
      for bad <- [:strict, "drop_block"] do
        assert_raise ArgumentError,
                     ~r/enable_adaptive_thinking\/2 :block_binding must be :error or :drop_block; got/,
                     fn ->
                       Request.enable_adaptive_thinking(Request.new("m"), block_binding: bad)
                     end
      end
    end
  end

  describe "set_thinking_block_binding/2" do
    @binding %{"prefix_mismatch_behavior" => "drop_block"}

    test "merges into adaptive thinking set earlier, keeping display" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :summarized)
        |> Request.set_thinking_block_binding(:drop_block)

      assert Request.to_map(request)["thinking"] == %{
               "type" => "adaptive",
               "display" => "summarized",
               "block_binding" => @binding
             }

      assert Request.required_betas(request) == ["thinking-binding-controls-2026-08-01"]
    end

    test "merges into a raw enabled thinking map" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 2048})
        |> Request.set_thinking_block_binding(:error)

      assert Request.to_map(request)["thinking"] == %{
               "type" => "enabled",
               "budget_tokens" => 2048,
               "block_binding" => %{"prefix_mismatch_behavior" => "error"}
             }
    end

    test "an atom-keyed raw map gains the string key only (Review Focus 1)" do
      request =
        Request.new("m")
        |> Request.enable_thinking(%{type: "enabled", budget_tokens: 2048})
        |> Request.set_thinking_block_binding(:drop_block)

      assert request.thinking == %{
               "block_binding" => @binding,
               type: "enabled",
               budget_tokens: 2048
             }
    end

    test "an atom :block_binding key is replaced, not duplicated" do
      request =
        Request.new("m")
        |> Request.enable_thinking(%{
          type: "adaptive",
          block_binding: %{prefix_mismatch_behavior: "error"}
        })
        |> Request.set_thinking_block_binding(:drop_block)

      assert request.thinking == %{"block_binding" => @binding, type: "adaptive"}
    end

    test "a later disable_thinking/1 replaces it" do
      request =
        Request.new("m")
        |> Request.enable_adaptive_thinking()
        |> Request.set_thinking_block_binding(:error)
        |> Request.disable_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "disabled"}
    end

    test "no thinking set, or a bad value, raises" do
      assert_raise ArgumentError, ~r/set_thinking_block_binding\/2 needs thinking/, fn ->
        Request.set_thinking_block_binding(Request.new("m"), :error)
      end

      assert_raise ArgumentError,
                   ~r/set_thinking_block_binding\/2 behavior must be :error or :drop_block; got/,
                   fn ->
                     Request.new("m")
                     |> Request.enable_adaptive_thinking()
                     |> Request.set_thinking_block_binding(:strict)
                   end
    end
  end

  describe "disable_thinking/2" do
    test "emits type disabled" do
      request = Request.new("claude-opus-5") |> Request.disable_thinking()
      assert Request.to_map(request)["thinking"] == %{"type" => "disabled"}
    end

    test "replaces a prior adaptive config (no display survives)" do
      request =
        Request.new("claude-opus-5")
        |> Request.enable_adaptive_thinking(display: :summarized)
        |> Request.disable_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "disabled"}
    end

    test "mode: :between_tools sends between_tools" do
      r = Request.new("claude-sonnet-5-5") |> Request.disable_thinking(mode: :between_tools)
      assert Request.to_map(r)["thinking"] == %{"type" => "between_tools"}
    end

    test "mode: :disabled is the explicit default" do
      r = Request.new("m") |> Request.disable_thinking(mode: :disabled)
      assert Request.to_map(r)["thinking"] == %{"type" => "disabled"}
    end

    test "rejects an unknown mode" do
      assert_raise ArgumentError,
                   ~r/disable_thinking\/2 :mode must be :disabled or :between_tools; got :off/,
                   fn -> Request.disable_thinking(Request.new("m"), mode: :off) end
    end

    test "rejects an unknown option" do
      assert_raise ArgumentError, ~r/unknown option :foo/, fn ->
        Request.disable_thinking(Request.new("m"), foo: 1)
      end
    end
  end

  describe "set_effort/2" do
    test "each level is emitted as a string under output_config.effort, no beta" do
      for level <- [:low, :medium, :high, :xhigh, :max] do
        request = Request.new("claude-opus-5-5") |> Request.set_effort(level)

        assert Request.to_map(request)["output_config"] == %{"effort" => Atom.to_string(level)}
        assert Request.required_betas(request) == []
      end
    end

    test "unknown levels raise" do
      for bad <- [:ultra, "high", nil] do
        assert_raise ArgumentError,
                     ~r/set_effort\/2 level must be one of :low, :medium, :high, :xhigh, :max; got/,
                     fn -> Request.new("claude-opus-5-5") |> Request.set_effort(bad) end
      end
    end
  end

  describe "set_task_budget/3" do
    @beta "task-budgets-2026-03-13"

    test "emits a tokens budget and declares the beta" do
      request = Request.new("claude-opus-5-5") |> Request.set_task_budget(64_000)

      assert Request.to_map(request)["output_config"] == %{
               "task_budget" => %{"type" => "tokens", "total" => 64_000}
             }

      assert Request.required_betas(request) == [@beta]
    end

    test "remaining is included when given; 0 is accepted" do
      for remaining <- [20_000, 0] do
        request =
          Request.new("claude-opus-5-5")
          |> Request.set_task_budget(64_000, remaining: remaining)

        assert Request.to_map(request)["output_config"]["task_budget"] == %{
                 "type" => "tokens",
                 "total" => 64_000,
                 "remaining" => remaining
               }
      end
    end

    test "calling twice replaces the budget and declares the beta once" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_task_budget(64_000, remaining: 10_000)
        |> Request.set_task_budget(30_000)

      assert Request.to_map(request)["output_config"]["task_budget"] == %{
               "type" => "tokens",
               "total" => 30_000
             }

      assert Request.required_betas(request) == [@beta]
    end

    test "total must be a positive integer (no local 20k floor)" do
      assert Request.new("m") |> Request.set_task_budget(1) |> Request.to_map()

      for bad <- [0, -1, 1.5, "64000", nil] do
        assert_raise ArgumentError,
                     ~r/set_task_budget\/3 total must be a positive integer; got/,
                     fn -> Request.new("m") |> Request.set_task_budget(bad) end
      end
    end

    test "remaining must be a non-negative integer" do
      for bad <- [-1, 2.5, "10", nil] do
        assert_raise ArgumentError,
                     ~r/set_task_budget\/3 :remaining must be a non-negative integer; got/,
                     fn -> Request.new("m") |> Request.set_task_budget(64_000, remaining: bad) end
      end
    end

    test "unknown option keys raise" do
      assert_raise ArgumentError, fn ->
        Request.new("m") |> Request.set_task_budget(64_000, max: 1)
      end
    end
  end

  describe "output_config composition" do
    @schema %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "string"}},
      "required" => ["a"],
      "additionalProperties" => false
    }

    test "effort, task budget and format merge in any order" do
      a =
        Request.new("m")
        |> Request.set_effort(:high)
        |> Request.set_task_budget(64_000)
        |> Request.set_output_format(@schema)

      b =
        Request.new("m")
        |> Request.set_output_format(@schema)
        |> Request.set_task_budget(64_000)
        |> Request.set_effort(:high)

      assert Request.to_map(a)["output_config"] == Request.to_map(b)["output_config"]

      assert Map.keys(Request.to_map(a)["output_config"]) |> Enum.sort() ==
               ["effort", "format", "task_budget"]
    end

    test "set_output_config/2 afterwards replaces the whole map" do
      request =
        Request.new("m")
        |> Request.set_effort(:high)
        |> Request.set_task_budget(64_000)
        |> Request.set_output_config(%{"effort" => "low"})

      assert Request.to_map(request)["output_config"] == %{"effort" => "low"}
    end
  end

  describe "output_config helpers over an atom-keyed raw map" do
    test "merge without leaving duplicate atom/string keys" do
      request =
        Request.new("m")
        |> Request.set_output_config(%{effort: "low", format: %{"type" => "json_schema"}})
        |> Request.set_effort(:high)

      assert Request.to_map(request)["output_config"] == %{
               "effort" => "high",
               "format" => %{"type" => "json_schema"}
             }

      assert Jason.encode!(Request.to_map(request)["output_config"])
             |> String.split("effort")
             |> length() == 2
    end
  end

  describe "add_system_message/3" do
    @clear_at_beta "mid-conversation-system-clear-at-2026-08-21"
    @msg_effort_beta "mid-conversation-output-config-2026-07-01"

    test "string content appends a system message, no beta" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_message(:user, "Hi")
        |> Request.add_message(:assistant, "Hello")
        |> Request.add_message(:user, "Continue")
        |> Request.add_system_message("Reply in French.")

      assert Request.to_map(request)["messages"] == [
               %{"role" => "user", "content" => "Hi"},
               %{"role" => "assistant", "content" => "Hello"},
               %{"role" => "user", "content" => "Continue"},
               %{"role" => "system", "content" => "Reply in French."}
             ]

      assert Request.required_betas(request) == []
    end

    test "block content is passed through unchanged" do
      blocks = [%{"type" => "text", "text" => "Be brief."}]
      request = Request.new("m") |> Request.add_system_message(blocks)

      assert [%{"role" => "system", "content" => ^blocks}] = Request.to_map(request)["messages"]
    end

    test "clear_at emits the field and declares its beta once" do
      for clear_at <- [:next_user_message, :never] do
        request =
          Request.new("m")
          |> Request.add_system_message("a", clear_at: clear_at)
          |> Request.add_system_message("b", clear_at: clear_at)

        [first, _] = Request.to_map(request)["messages"]
        assert first["clear_at"] == Atom.to_string(clear_at)
        assert Request.required_betas(request) == [@clear_at_beta]
      end
    end

    test "effort emits output_config and declares its beta" do
      for level <- [:low, :medium, :high, :xhigh, :max] do
        request = Request.new("m") |> Request.add_system_message([], effort: level)

        assert Request.to_map(request)["messages"] == [
                 %{
                   "role" => "system",
                   "content" => [],
                   "output_config" => %{"effort" => Atom.to_string(level)}
                 }
               ]

        assert Request.required_betas(request) == [@msg_effort_beta]
      end
    end

    test "content plus effort is allowed (not turn-scoped)" do
      request = Request.new("m") |> Request.add_system_message("Be brief.", effort: :low)

      assert [%{"content" => "Be brief.", "output_config" => %{"effort" => "low"}}] =
               Request.to_map(request)["messages"]
    end

    test "nil options behave as if absent" do
      request =
        Request.new("m") |> Request.add_system_message("a", clear_at: nil, effort: nil)

      assert Request.to_map(request)["messages"] == [%{"role" => "system", "content" => "a"}]
      assert Request.required_betas(request) == []
    end

    test "unknown clear_at and effort values raise" do
      assert_raise ArgumentError,
                   ~r/add_system_message\/3 :clear_at must be one of :next_user_message, :never; got/,
                   fn -> Request.new("m") |> Request.add_system_message("a", clear_at: :later) end

      assert_raise ArgumentError,
                   ~r/add_system_message\/3 :effort must be one of :low, :medium, :high, :xhigh, :max; got/,
                   fn -> Request.new("m") |> Request.add_system_message("a", effort: "low") end
    end

    test "a turn-scoped message cannot carry effort" do
      assert_raise ArgumentError,
                   ~r/add_system_message\/3 clear_at: :next_user_message cannot be combined with :effort/,
                   fn ->
                     Request.new("m")
                     |> Request.add_system_message("a",
                       clear_at: :next_user_message,
                       effort: :low
                     )
                   end
    end

    test "empty content needs effort" do
      assert_raise ArgumentError,
                   ~r/add_system_message\/3 empty content \[\] requires :effort/,
                   fn -> Request.new("m") |> Request.add_system_message([]) end
    end

    test "unknown option keys raise" do
      assert_raise ArgumentError, ~r/add_system_message\/3: unknown option :cache_control/, fn ->
        Request.new("m") |> Request.add_system_message("a", cache_control: %{})
      end
    end
  end

  describe "set_speed/2" do
    test "each value is emitted and always declares the fast-mode beta" do
      for speed <- [:fast, :standard] do
        request = Request.new("claude-opus-5-5") |> Request.set_speed(speed)

        assert Request.to_map(request)["speed"] == Atom.to_string(speed)
        assert Request.required_betas(request) == ["fast-mode-2026-02-01"]
      end
    end

    test "unknown values raise" do
      for bad <- [:turbo, "fast", nil] do
        assert_raise ArgumentError,
                     ~r/set_speed\/2 speed must be one of :fast, :standard; got/,
                     fn ->
                       Request.new("m") |> Request.set_speed(bad)
                     end
      end
    end
  end

  describe "set_inference_geo/2" do
    test "each value is emitted, no beta" do
      for geo <- [:global, :us] do
        request = Request.new("claude-opus-5-5") |> Request.set_inference_geo(geo)

        assert Request.to_map(request)["inference_geo"] == Atom.to_string(geo)
        assert Request.required_betas(request) == []
      end
    end

    test "unknown values raise" do
      for bad <- [:eu, "us", nil] do
        assert_raise ArgumentError,
                     ~r/set_inference_geo\/2 geo must be one of :global, :us; got/,
                     fn -> Request.new("m") |> Request.set_inference_geo(bad) end
      end
    end
  end

  describe "set_fallbacks/2" do
    test ":default is emitted as \"default\" and declares the fallback beta" do
      request = Request.new("claude-opus-5-5") |> Request.set_fallbacks(:default)

      assert Request.to_map(request)["fallbacks"] == "default"
      assert Request.required_betas(request) == ["server-side-fallback-2026-07-01"]
    end

    test "model strings become model entries, maps pass through, order kept" do
      override = %{"model" => "claude-opus-5", "max_tokens" => 512}

      request =
        Request.new("claude-opus-5-5")
        |> Request.set_fallbacks(["claude-opus-4-8", override])

      assert Request.to_map(request)["fallbacks"] == [
               %{"model" => "claude-opus-4-8"},
               override
             ]
    end

    test "calling twice replaces the value and declares the beta once" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_fallbacks(["claude-opus-4-8"])
        |> Request.set_fallbacks(:default)

      assert Request.to_map(request)["fallbacks"] == "default"
      assert Request.required_betas(request) == ["server-side-fallback-2026-07-01"]
    end

    test "four entries are sent as-is (the three-entry cap is the API's)" do
      models = ["a", "b", "c", "d"]
      request = Request.new("m") |> Request.set_fallbacks(models)

      assert length(Request.to_map(request)["fallbacks"]) == 4
    end

    test "without set_fallbacks/2 there is no fallbacks key and no beta" do
      request = Request.new("m") |> Request.add_message(:user, "hi")

      refute Map.has_key?(Request.to_map(request), "fallbacks")
      assert Request.required_betas(request) == []
    end

    test "shapes other than :default or a non-empty list raise" do
      for bad <- ["default", :auto, nil, [], %{"model" => "x"}] do
        assert_raise ArgumentError,
                     ~r/set_fallbacks\/2 fallbacks must be :default or a non-empty list of model strings or maps; got/,
                     fn -> Request.new("m") |> Request.set_fallbacks(bad) end
      end
    end

    test "an entry that is neither a string nor a map raises" do
      for bad <- [:"claude-opus-4-8", nil, 1] do
        assert_raise ArgumentError,
                     ~r/set_fallbacks\/2 each entry must be a model string or a map; got/,
                     fn -> Request.new("m") |> Request.set_fallbacks(["ok", bad]) end
      end
    end
  end

  describe "enable_cache_diagnostics/2" do
    test "defaults previous_message_id to nil, no beta" do
      request = Request.new("m") |> Request.enable_cache_diagnostics()

      assert Request.to_map(request)["diagnostics"] == %{"previous_message_id" => nil}
      assert Request.required_betas(request) == []
    end

    test "carries a previous message id" do
      request = Request.new("m") |> Request.enable_cache_diagnostics("msg_01")
      assert Request.to_map(request)["diagnostics"] == %{"previous_message_id" => "msg_01"}
    end

    test "a non-string id raises" do
      for bad <- [123, :msg, %{}] do
        assert_raise ArgumentError,
                     ~r/enable_cache_diagnostics\/2 previous_message_id must be a string or nil; got/,
                     fn -> Request.new("m") |> Request.enable_cache_diagnostics(bad) end
      end
    end
  end

  describe "to_map/1 without the S12a setters" do
    test "emits no speed, inference_geo or diagnostics keys" do
      map = Request.new("m") |> Request.add_message(:user, "hi") |> Request.to_map()

      assert map == %{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}
    end
  end

  describe "add_message/3 with parsed Response content (pre-release audit)" do
    # Live probe G2 (2026-09-26): "caller": null is rejected ("Input should be an object").
    test "typed blocks are sent in API shape, without nil fields" do
      raw = [
        %{"type" => "text", "text" => "Checking"},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "f", "input" => %{"a" => 1}},
        %{"type" => "server_tool_use", "id" => "srv_1", "name" => "web_search", "input" => %{}}
      ]

      response = Response.from_map(%{"content" => raw})
      request = Request.new("m") |> Request.add_message(:assistant, response.content)

      assert request.messages == [%{"role" => "assistant", "content" => raw}]
      assert Jason.encode!(request.messages) =~ ~s("toolu_1")
      refute Jason.encode!(request.messages) =~ "null"
    end
  end

  describe "tool helper robustness (pre-release audit)" do
    test "atom-keyed tool maps don't get duplicate JSON keys" do
      base = %{name: "x", description: "d", input_schema: %{type: "object"}}

      for request <- [
            Request.add_strict_tool(Request.new("m"), Map.put(base, :strict, false)),
            Request.add_tool_with_eager_streaming(
              Request.new("m"),
              Map.put(base, :eager_input_streaming, false)
            ),
            Request.add_tool_with_cache(
              Request.new("m"),
              Map.put(base, :cache_control, %{type: "ephemeral"}),
              ttl: "1h"
            ),
            Request.add_tool(Request.new("m"), Map.put(base, :defer_loading, false),
              defer_loading: true
            )
          ] do
        [tool] = request.tools
        # An atom key and its string twin would encode as the same JSON key twice.
        names = tool |> Map.keys() |> Enum.map(&to_string/1)
        assert names == Enum.uniq(names), "duplicate key in #{inspect(tool)}"
      end
    end

    test "add_tool_with_cache/3 validates options and passes allowed_callers on" do
      tool = %{"name" => "x", "description" => "d", "input_schema" => %{"type" => "object"}}

      request =
        Request.add_tool_with_cache(Request.new("m"), tool, allowed_callers: [:code_execution])

      assert [%{"allowed_callers" => ["code_execution_20260120"], "cache_control" => _}] =
               request.tools

      # defer_loading + cache_control on one tool is an API 400 (spec F2); a typo must not vanish.
      assert_raise ArgumentError, fn ->
        Request.add_tool_with_cache(Request.new("m"), tool, defer_loading: true)
      end

      assert_raise ArgumentError, fn ->
        Request.add_tool_with_cache(Request.new("m"), tool, tll: "1h")
      end
    end

    test "server tool helpers validate options and accept dated version atoms" do
      assert_raise ArgumentError, fn ->
        Request.add_web_search_tool(Request.new("m"), max_use: 3)
      end

      assert_raise ArgumentError, fn ->
        Request.add_web_fetch_tool(Request.new("m"), max_use: 3)
      end

      assert_raise ArgumentError, fn ->
        Request.add_text_editor_tool(Request.new("m"), max_chars: 3)
      end

      assert [%{"type" => "web_search_20260209"}] =
               Request.add_web_search_tool(Request.new("m"), version: :"20260209").tools

      assert [%{"type" => "web_fetch_20250910"}] =
               Request.add_web_fetch_tool(Request.new("m"), version: :"20250910").tools
    end

    test "bad search_result cache_control and toolset configs raise ArgumentError" do
      assert_raise ArgumentError, ~r/cache_control/, fn ->
        Request.search_result_block("s", "t", ["x"], cache_control: :ephemeral)
      end

      assert_raise ArgumentError, ~r/:configs/, fn ->
        Request.add_computer_toolset(Request.new("m"), configs: "bad")
      end
    end

    test "context-edit option types are checked; a second clear_thinking replaces the first" do
      r = Request.new("m")

      assert_raise ArgumentError, ~r/:exclude_tools/, fn ->
        Request.add_clear_tool_uses(r, exclude_tools: "bash")
      end

      assert_raise ArgumentError, ~r/:clear_tool_inputs/, fn ->
        Request.add_clear_tool_uses(r, clear_tool_inputs: "yes")
      end

      request =
        r
        |> Request.add_clear_thinking(keep: 1)
        |> Request.add_clear_tool_uses()
        |> Request.add_clear_thinking(keep: :all)

      assert [
               %{"type" => "clear_thinking_20251015", "keep" => "all"},
               %{"type" => "clear_tool_uses_20250919"}
             ] =
               request.context_management["edits"]
    end
  end

  describe "add_message_with_image/5 media type (pre-release audit)" do
    defp image_media_type(request) do
      [%{"content" => [%{"source" => %{"media_type" => type}}, _]}] = request.messages
      type
    end

    test "without a media type, PNG/GIF/WebP/JPEG are detected from the data" do
      for {bytes, type} <- [
            {<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0>>, "image/png"},
            {"GIF89a" <> <<0, 0>>, "image/gif"},
            {"RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ", "image/webp"},
            {<<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>, "image/jpeg"}
          ] do
        request =
          Request.new("m") |> Request.add_message_with_image(:user, "?", Base.encode64(bytes))

        assert image_media_type(request) == type
      end
    end

    test "unrecognized data keeps the documented image/jpeg default; an explicit type wins" do
      assert Request.new("m")
             |> Request.add_message_with_image(:user, "?", "abc")
             |> image_media_type() ==
               "image/jpeg"

      png = Base.encode64(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>)

      assert Request.new("m")
             |> Request.add_message_with_image(:user, "?", png, "image/webp")
             |> image_media_type() == "image/webp"
    end

    test "add_message_with_image/5 accepts media_type: as a keyword" do
      r =
        Request.new("m")
        |> Request.add_message_with_image(:user, "t", "AAAA", media_type: "image/png")

      [%{"content" => [%{"source" => source}, _]}] = Request.to_map(r)["messages"]
      assert source["media_type"] == "image/png"
    end

    test "add_message_with_image/5 rejects unknown keyword options" do
      assert_raise ArgumentError, ~r/add_message_with_image\/5: unknown option :mime/, fn ->
        Request.new("m") |> Request.add_message_with_image(:user, "t", "AAAA", mime: "image/png")
      end
    end
  end

  describe "re-audit: typed blocks keep cache_control" do
    test "a typed block with cache_control keeps the breakpoint" do
      request =
        Request.new("m")
        |> Request.add_message(:user, [
          %{type: :text, text: "hi", cache_control: %{"type" => "ephemeral"}}
        ])

      assert [
               %{
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "hi",
                     "cache_control" => %{"type" => "ephemeral"}
                   }
                 ]
               }
             ] =
               request.messages
    end
  end

  describe "unknown option errors name the function" do
    # {function, arguments between the request and opts}
    @calls [
      {:add_tool, [%{"name" => "t", "input_schema" => %{"type" => "object"}}]},
      {:add_tool_with_cache, [%{"name" => "t", "input_schema" => %{"type" => "object"}}]},
      {:enable_adaptive_thinking, []},
      {:add_clear_tool_uses, []},
      {:add_clear_thinking, []},
      {:add_compaction, []},
      {:request_compaction, []},
      {:set_task_budget, [20_000]},
      {:add_system_message, ["s"]},
      {:add_advisor_tool, ["claude-opus-5-5"]},
      {:add_computer_toolset, []},
      {:add_browser_toolset, []},
      {:add_web_search_tool, []},
      {:add_web_fetch_tool, []},
      {:add_text_editor_tool, []},
      {:add_computer_tool, [1024, 768]}
    ]

    for {fun, args} <- @calls do
      @fun fun
      @args args
      @name "Request.#{fun}/#{length(args) + 2}"
      test @name do
        error =
          assert_raise ArgumentError, fn ->
            apply(Request, @fun, [Request.new("m")] ++ @args ++ [[bogus: true]])
          end

        assert String.starts_with?(error.message, "#{@name}: unknown option :bogus; allowed: :")
      end

      test "#{@name} with non-keyword opts" do
        assert_raise ArgumentError,
                     "#{@name}: options must be a keyword list; got %{bogus: true}",
                     fn ->
                       apply(Request, @fun, [Request.new("m")] ++ @args ++ [%{bogus: true}])
                     end
      end
    end
  end

  describe "cache and document option validation" do
    test "misspelled cache option raises" do
      assert_raise ArgumentError,
                   ~r/Request.set_system_with_cache\/3: unknown option :cache_ttl/,
                   fn ->
                     Request.new("m") |> Request.set_system_with_cache("s", cache_ttl: "1h")
                   end
    end

    test "bad ttl value raises on every cache helper" do
      r = Request.new("m")

      assert_raise ArgumentError, ~r/:ttl must be "5m" or "1h"; got :one_hour/, fn ->
        Request.set_system_with_cache(r, "s", ttl: :one_hour)
      end

      assert_raise ArgumentError, ~r/:ttl must be "5m" or "1h"; got 3600/, fn ->
        Request.set_cache_control(r, ttl: 3600)
      end

      assert_raise ArgumentError, ~r/:ttl/, fn ->
        Request.add_message_with_cache(r, :user, "t", ttl: "2h")
      end

      assert_raise ArgumentError, ~r/:ttl/, fn ->
        Request.add_tool_with_cache(r, %{"name" => "t"}, ttl: "2h")
      end
    end

    test "valid ttls still work" do
      r = Request.new("m") |> Request.set_cache_control(ttl: "1h")
      assert Request.to_map(r)["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
    end

    test "misspelled document option raises" do
      assert_raise ArgumentError,
                   ~r/add_message_with_document\/5: unknown option :citation/,
                   fn ->
                     Request.new("m")
                     |> Request.add_message_with_document(:user, "t", "file_1", citation: true)
                   end
    end

    test "search_result_block/4 rejects unknown options" do
      assert_raise ArgumentError, ~r/search_result_block\/4: unknown option :ttl/, fn ->
        Request.search_result_block("src", "title", ["x"], ttl: "1h")
      end
    end
  end

  describe "argument errors name the fix" do
    setup do: %{r: Request.new("m")}

    test "add_message with :system points to set_system / add_system_message", %{r: r} do
      assert_raise ArgumentError, ~r/set_system\/2.*add_system_message\/3/s, fn ->
        Request.add_message(r, :system, "x")
      end
    end

    test "add_message with a string role", %{r: r} do
      assert_raise ArgumentError, ~r/role must be :user or :assistant; got "user"/, fn ->
        Request.add_message(r, "user", "x")
      end
    end

    test "add_message with nil content", %{r: r} do
      assert_raise ArgumentError,
                   ~r/content must be a string or a list of content blocks; got nil/,
                   fn -> Request.add_message(r, :user, nil) end
    end

    test "set_temperature out of range", %{r: r} do
      assert_raise ArgumentError,
                   ~r/set_temperature\/2: temperature must be a number between 0.0 and 1.0; got 1.5/,
                   fn -> Request.set_temperature(r, 1.5) end
    end

    test "set_top_p out of range", %{r: r} do
      assert_raise ArgumentError, ~r/set_top_p\/2/, fn -> Request.set_top_p(r, 2) end
    end

    test "set_top_k non-positive", %{r: r} do
      assert_raise ArgumentError,
                   ~r/set_top_k\/2: top_k must be a positive integer; got 0/,
                   fn -> Request.set_top_k(r, 0) end
    end

    test "set_max_tokens with a string", %{r: r} do
      assert_raise ArgumentError,
                   ~r/set_max_tokens\/2: max_tokens must be a positive integer; got "1024"/,
                   fn -> Request.set_max_tokens(r, "1024") end
    end

    test "set_max_tokens with zero", %{r: r} do
      assert_raise ArgumentError, ~r/positive integer; got 0/, fn ->
        Request.set_max_tokens(r, 0)
      end
    end

    test "set_tool_choice with a string", %{r: r} do
      assert_raise ArgumentError,
                   ~r/set_tool_choice\/2: expected :auto, :any, :none or \{:tool, name\}; got "auto"/,
                   fn -> Request.set_tool_choice(r, "auto") end
    end

    test "add_tool with a keyword list points to Tools.define_tool/3", %{r: r} do
      assert_raise ArgumentError,
                   ~r/add_tool\/3: tool must be a map.*Tools.define_tool\/3/s,
                   fn ->
                     Request.add_tool(r, name: "x")
                   end
    end

    test "enable_thinking with a keyword list points to enable_adaptive_thinking/2", %{r: r} do
      assert_raise ArgumentError,
                   ~r/enable_thinking\/2: config must be a map.*enable_adaptive_thinking\/2/s,
                   fn -> Request.enable_thinking(r, budget_tokens: 1024) end
    end
  end
end
