defmodule Claudio.Messages.ResponseTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Response
  alias Claudio.Messages.Request

  describe "from_map/1" do
    test "parses basic response with string keys" do
      data = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20241022",
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)

      assert response.id == "msg_123"
      assert response.role == "assistant"
      assert response.stop_reason == :end_turn

      assert response.usage == %{
               input_tokens: 10,
               output_tokens: 5,
               cache_creation_input_tokens: nil,
               cache_read_input_tokens: nil,
               output_tokens_details: nil,
               cache_creation: nil,
               service_tier: nil,
               inference_geo: nil,
               speed: nil
             }
    end

    test "parses response with atom keys" do
      data = %{
        id: "msg_123",
        type: "message",
        role: "assistant",
        model: "claude-3-5-sonnet-20241022",
        content: [%{type: "text", text: "Hello!"}],
        stop_reason: "max_tokens",
        usage: %{input_tokens: 10, output_tokens: 5}
      }

      response = Response.from_map(data)

      assert response.id == "msg_123"
      assert response.stop_reason == :max_tokens
    end

    test "parses all stop reason types" do
      stop_reasons = [
        {"end_turn", :end_turn},
        {"max_tokens", :max_tokens},
        {"stop_sequence", :stop_sequence},
        {"tool_use", :tool_use},
        {"pause_turn", :pause_turn},
        {"refusal", :refusal},
        {"model_context_window_exceeded", :model_context_window_exceeded}
      ]

      for {api_reason, expected_atom} <- stop_reasons do
        data = %{
          "id" => "msg_123",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-3-5-sonnet-20241022",
          "content" => [],
          "stop_reason" => api_reason,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        response = Response.from_map(data)
        assert response.stop_reason == expected_atom
      end
    end

    test "parses text content blocks" do
      data = %{
        "id" => "msg_123",
        "content" => [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "text", "text" => " world"}
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)

      assert length(response.content) == 2
      assert Enum.at(response.content, 0).type == :text
      assert Enum.at(response.content, 0).text == "Hello"
      assert Enum.at(response.content, 1).text == " world"
    end

    test "parses tool use content blocks" do
      data = %{
        "id" => "msg_123",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "get_weather",
            "input" => %{"location" => "Paris"}
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)

      assert length(response.content) == 1
      tool_use = Enum.at(response.content, 0)
      assert tool_use.type == :tool_use
      assert tool_use.id == "toolu_123"
      assert tool_use.name == "get_weather"
      assert tool_use.input == %{"location" => "Paris"}
    end
  end

  describe "get_text/1" do
    test "extracts text from single text block" do
      response = %Response{
        content: [%{type: :text, text: "Hello world"}]
      }

      assert Response.get_text(response) == "Hello world"
    end

    test "concatenates multiple text blocks" do
      response = %Response{
        content: [
          %{type: :text, text: "Hello"},
          %{type: :text, text: " "},
          %{type: :text, text: "world"}
        ]
      }

      assert Response.get_text(response) == "Hello world"
    end

    test "ignores non-text blocks" do
      response = %Response{
        content: [
          %{type: :text, text: "Hello"},
          %{type: :tool_use, id: "toolu_1", name: "tool", input: %{}},
          %{type: :text, text: "world"}
        ]
      }

      assert Response.get_text(response) == "Helloworld"
    end

    test "returns empty string for no text blocks" do
      response = %Response{
        content: [%{type: :tool_use, id: "toolu_1", name: "tool", input: %{}}]
      }

      assert Response.get_text(response) == ""
    end
  end

  describe "get_tool_uses/1" do
    test "extracts tool use blocks" do
      response = %Response{
        content: [
          %{type: :text, text: "Let me check"},
          %{type: :tool_use, id: "toolu_1", name: "get_weather", input: %{"location" => "NYC"}},
          %{type: :tool_use, id: "toolu_2", name: "get_time", input: %{"timezone" => "EST"}}
        ]
      }

      tool_uses = Response.get_tool_uses(response)

      assert length(tool_uses) == 2
      assert Enum.at(tool_uses, 0).name == "get_weather"
      assert Enum.at(tool_uses, 1).name == "get_time"
    end

    test "returns empty list when no tool uses" do
      response = %Response{
        content: [%{type: :text, text: "Just text"}]
      }

      assert Response.get_tool_uses(response) == []
    end
  end

  describe "from_map/1 thinking blocks" do
    test "preserves signature on thinking blocks (string keys)" do
      data = %{
        "content" => [%{"type" => "thinking", "thinking" => "hmm", "signature" => "sig_abc"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      response = Response.from_map(data)

      assert [%{type: :thinking, thinking: "hmm", signature: "sig_abc"}] = response.content
    end

    test "preserves signature on thinking blocks (atom keys)" do
      data = %{
        content: [%{type: "thinking", thinking: "hmm", signature: "sig_abc"}],
        usage: %{input_tokens: 1, output_tokens: 1}
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

      assert Response.to_assistant_content(response) == [
               %{"type" => "thinking", "thinking" => "x"}
             ]
    end

    test "passes unknown block types through unchanged" do
      response = %Response{
        content: [%{type: :unknown_future_type, some_field: "value"}]
      }

      assert Response.to_assistant_content(response) ==
               [%{type: :unknown_future_type, some_field: "value"}]
    end

    test "serializes mcp_tool_use blocks to API shape" do
      response = %Response{
        content: [
          %{
            type: :mcp_tool_use,
            id: "mcp_1",
            name: "search",
            server_name: "srv",
            input: %{"q" => "x"}
          }
        ]
      }

      assert Response.to_assistant_content(response) == [
               %{
                 "type" => "mcp_tool_use",
                 "id" => "mcp_1",
                 "name" => "search",
                 "server_name" => "srv",
                 "input" => %{"q" => "x"}
               }
             ]
    end

    test "serializes mcp_tool_result blocks to API shape" do
      response = %Response{
        content: [
          %{
            type: :mcp_tool_result,
            tool_use_id: "mcp_1",
            server_name: "srv",
            content: "ok",
            is_error: false
          }
        ]
      }

      assert Response.to_assistant_content(response) == [
               %{
                 "type" => "mcp_tool_result",
                 "tool_use_id" => "mcp_1",
                 "server_name" => "srv",
                 "content" => "ok",
                 "is_error" => false
               }
             ]
    end
  end

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

      assert %{"type" => "thinking", "thinking" => "reasoning", "signature" => "sig_abc"} =
               Enum.at(content, 0)

      assert %{"type" => "redacted_thinking", "data" => "enc_xyz"} = Enum.at(content, 1)

      assert %{"type" => "tool_use", "id" => "toolu_1", "name" => "get_weather"} =
               Enum.at(content, 2)
    end
  end

  describe "from_map/1 citations on text blocks" do
    @citation %{
      "type" => "char_location",
      "cited_text" => "The grass is green.",
      "document_index" => 0,
      "document_title" => "Example",
      "start_char_index" => 0,
      "end_char_index" => 20
    }

    test "preserves the citations array (string keys)" do
      data = %{
        "content" => [
          %{"type" => "text", "text" => "the grass is green", "citations" => [@citation]}
        ]
      }

      [block] = Response.from_map(data).content
      assert block.type == :text
      assert block.text == "the grass is green"
      assert block.citations == [@citation]
    end

    test "preserves the citations array (atom keys)" do
      data = %{content: [%{type: "text", text: "x", citations: [@citation]}]}
      [block] = Response.from_map(data).content
      assert block.citations == [@citation]
    end

    test "a text block without citations has no :citations key" do
      data = %{"content" => [%{"type" => "text", "text" => "no citations"}]}
      [block] = Response.from_map(data).content
      refute Map.has_key?(block, :citations)
    end

    test "get_text/1 still works for citation-bearing blocks" do
      data = %{
        "content" => [
          %{"type" => "text", "text" => "a "},
          %{"type" => "text", "text" => "cited claim", "citations" => [@citation]}
        ]
      }

      assert Response.get_text(Response.from_map(data)) == "a cited claim"
    end
  end

  describe "get_citations/1" do
    @c1 %{"type" => "char_location", "cited_text" => "one", "document_index" => 0}
    @c2 %{"type" => "page_location", "cited_text" => "two", "document_index" => 1}

    test "aggregates citations across all text blocks" do
      data = %{
        "content" => [
          %{"type" => "text", "text" => "a", "citations" => [@c1]},
          %{"type" => "text", "text" => "b"},
          %{"type" => "text", "text" => "c", "citations" => [@c2]}
        ]
      }

      assert Response.get_citations(Response.from_map(data)) == [@c1, @c2]
    end

    test "returns [] when there are no citations" do
      data = %{"content" => [%{"type" => "text", "text" => "plain"}]}
      assert Response.get_citations(Response.from_map(data)) == []
    end
  end

  describe "from_map/1 server-tool blocks" do
    @web_results [
      %{
        "type" => "web_search_result",
        "url" => "https://example.com",
        "title" => "Example",
        "encrypted_content" => "enc_abc",
        "page_age" => "2 days ago"
      }
    ]

    test "types a server_tool_use block (string keys)" do
      data = %{
        "content" => [
          %{
            "type" => "server_tool_use",
            "id" => "srvtoolu_1",
            "name" => "web_search",
            "input" => %{"query" => "elixir"}
          }
        ]
      }

      [block] = Response.from_map(data).content

      assert block == %{
               type: :server_tool_use,
               id: "srvtoolu_1",
               name: "web_search",
               input: %{"query" => "elixir"}
             }
    end

    test "types a server_tool_use block (atom keys)" do
      data = %{
        content: [
          %{type: "server_tool_use", id: "srvtoolu_2", name: "web_search", input: %{}}
        ]
      }

      [block] = Response.from_map(data).content
      assert block.type == :server_tool_use
      assert block.id == "srvtoolu_2"
    end

    test "types a web_search_tool_result block and preserves content (string keys)" do
      data = %{
        "content" => [
          %{
            "type" => "web_search_tool_result",
            "tool_use_id" => "srvtoolu_1",
            "content" => @web_results
          }
        ]
      }

      [block] = Response.from_map(data).content

      assert block == %{
               type: :web_search_tool_result,
               tool_use_id: "srvtoolu_1",
               content: @web_results
             }
    end

    test "types a web_search_tool_result block (atom keys)" do
      data = %{
        content: [%{type: "web_search_tool_result", tool_use_id: "srvtoolu_3", content: []}]
      }

      [block] = Response.from_map(data).content
      assert block.type == :web_search_tool_result
      assert block.tool_use_id == "srvtoolu_3"
    end

    test "round-trips both block types through to_assistant_content/1" do
      data = %{
        "content" => [
          %{
            "type" => "server_tool_use",
            "id" => "srvtoolu_1",
            "name" => "web_search",
            "input" => %{"query" => "elixir"}
          },
          %{
            "type" => "web_search_tool_result",
            "tool_use_id" => "srvtoolu_1",
            "content" => @web_results
          }
        ]
      }

      [stu, wstr] = data |> Response.from_map() |> Response.to_assistant_content()

      assert stu == %{
               "type" => "server_tool_use",
               "id" => "srvtoolu_1",
               "name" => "web_search",
               "input" => %{"query" => "elixir"}
             }

      assert wstr == %{
               "type" => "web_search_tool_result",
               "tool_use_id" => "srvtoolu_1",
               "content" => @web_results
             }
    end
  end

  describe "get_server_tool_uses/1" do
    test "extracts only server_tool_use blocks" do
      data = %{
        "content" => [
          %{"type" => "text", "text" => "searching"},
          %{"type" => "server_tool_use", "id" => "s1", "name" => "web_search", "input" => %{}},
          %{"type" => "web_search_tool_result", "tool_use_id" => "s1", "content" => []}
        ]
      }

      uses = Response.get_server_tool_uses(Response.from_map(data))
      assert [%{type: :server_tool_use, id: "s1"}] = uses
    end

    test "tolerates raw/untyped blocks (e.g. code_execution_tool_result) without crashing" do
      # Dynamic-filtering web_search returns code_execution_tool_result blocks
      # Claudio does not type — they pass through as raw string-keyed maps with
      # no atom :type key. Getters must not crash on them.
      data = %{
        "content" => [
          %{"type" => "server_tool_use", "id" => "s1", "name" => "web_search", "input" => %{}},
          %{"type" => "code_execution_tool_result", "tool_use_id" => "s1", "content" => %{}},
          %{"type" => "text", "text" => "done"}
        ]
      }

      response = Response.from_map(data)
      assert [%{type: :server_tool_use, id: "s1"}] = Response.get_server_tool_uses(response)
      assert Response.get_citations(response) == []
      assert Response.get_tool_uses(response) == []
      assert Response.get_text(response) == "done"
    end
  end

  describe "from_map/1 stop_details" do
    @details %{"type" => "refusal", "category" => "cyber", "explanation" => "declined"}

    test "keeps stop_details as a raw string-keyed map on refusal" do
      response =
        Response.from_map(%{
          "content" => [],
          "stop_reason" => "refusal",
          "stop_details" => @details
        })

      assert response.stop_reason == :refusal
      assert response.stop_details == @details
    end

    test "nil when absent" do
      assert Response.from_map(%{"content" => [], "stop_reason" => "end_turn"}).stop_details ==
               nil
    end

    test "atom-keyed stop_details" do
      response = Response.from_map(%{content: [], stop_reason: "refusal", stop_details: @details})
      assert response.stop_details == @details
    end
  end

  describe "from_map/1 usage.output_tokens_details" do
    test "string keys: carried raw" do
      response =
        Response.from_map(%{
          "content" => [],
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 50,
            "output_tokens_details" => %{"thinking_tokens" => 30}
          }
        })

      assert response.usage.output_tokens_details == %{"thinking_tokens" => 30}
    end

    test "atom keys: carried raw" do
      response =
        Response.from_map(%{
          content: [],
          usage: %{
            input_tokens: 10,
            output_tokens: 50,
            output_tokens_details: %{thinking_tokens: 30}
          }
        })

      assert response.usage.output_tokens_details == %{thinking_tokens: 30}
    end

    test "nil when absent, and when usage itself is absent" do
      with_usage =
        Response.from_map(%{
          "content" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
        })

      assert with_usage.usage.output_tokens_details == nil
      assert Response.from_map(%{"content" => []}).usage.output_tokens_details == nil
    end
  end

  describe "get_thinking/1" do
    test "returns non-empty thinking texts in content order" do
      response =
        Response.from_map(%{
          "content" => [
            %{"type" => "thinking", "thinking" => "", "signature" => "s0"},
            %{"type" => "thinking", "thinking" => "Checking the config", "signature" => "s1"},
            %{"type" => "tool_use", "id" => "t1", "name" => "read", "input" => %{}},
            %{"type" => "redacted_thinking", "data" => "opaque"},
            %{"type" => "text", "text" => "not thinking"},
            %{"type" => "thinking", "thinking" => "Now writing the fix", "signature" => "s2"}
          ]
        })

      assert Response.get_thinking(response) == ["Checking the config", "Now writing the fix"]
    end

    test "skips a thinking block with no thinking text instead of crashing" do
      response =
        Response.from_map(%{"content" => [%{"type" => "thinking", "signature" => "s"}]})

      assert Response.get_thinking(response) == []
    end

    test "keeps the interrupted placeholder (filter with thinking_interrupted?/1)" do
      placeholder = "This part of the response was interrupted before it finished."

      response =
        Response.from_map(%{
          "content" => [%{"type" => "thinking", "thinking" => placeholder, "signature" => "s"}]
        })

      assert Response.get_thinking(response) == [placeholder]
    end
  end

  describe "thinking_interrupted?/1" do
    @placeholder "This part of the response was interrupted before it finished."

    test "true only for a thinking block whose text is exactly the placeholder" do
      assert Response.thinking_interrupted?(%{
               type: :thinking,
               thinking: @placeholder,
               signature: "s"
             })
    end

    test "false for other thinking text, a text block with the same string, and redacted_thinking" do
      refute Response.thinking_interrupted?(%{
               type: :thinking,
               thinking: "working",
               signature: "s"
             })

      refute Response.thinking_interrupted?(%{
               type: :thinking,
               thinking: @placeholder <> " ",
               signature: "s"
             })

      refute Response.thinking_interrupted?(%{type: :text, text: @placeholder})
      refute Response.thinking_interrupted?(%{type: :redacted_thinking, data: "x"})
    end
  end

  describe "from_map/1 usage keeps every field" do
    test "new documented fields become atom keys (string-keyed input)" do
      usage =
        Response.from_map(%{
          "content" => [],
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "cache_creation" => %{"ephemeral_5m_input_tokens" => 0},
            "service_tier" => "standard",
            "inference_geo" => "us",
            "speed" => "fast"
          }
        }).usage

      assert usage.cache_creation == %{"ephemeral_5m_input_tokens" => 0}
      assert usage.service_tier == "standard"
      assert usage.inference_geo == "us"
      assert usage.speed == "fast"
    end

    test "atom-keyed input works too" do
      usage =
        Response.from_map(%{
          content: [],
          usage: %{input_tokens: 1, output_tokens: 2, inference_geo: "global"}
        }).usage

      assert usage.inference_geo == "global"
      assert usage.speed == nil
    end

    test "unknown fields survive under their original key" do
      string_keyed =
        Response.from_map(%{
          "content" => [],
          "usage" => %{
            "input_tokens" => 1,
            "output_tokens" => 2,
            "iterations" => [%{"type" => "message"}]
          }
        }).usage

      assert string_keyed["iterations"] == [%{"type" => "message"}]

      atom_keyed =
        Response.from_map(%{
          content: [],
          usage: %{input_tokens: 1, output_tokens: 2, future_field: 7}
        }).usage

      assert atom_keyed[:future_field] == 7
    end

    test "a documented field under both key styles yields one atom key, atom value wins" do
      usage =
        Response.from_map(%{
          content: [],
          usage: %{
            :input_tokens => 1,
            :output_tokens => 2,
            :speed => "fast",
            "speed" => "standard"
          }
        }).usage

      assert usage.speed == "fast"
      refute Map.has_key?(usage, "speed")
    end

    test "nil usage has the new keys as nil" do
      usage = Response.from_map(%{"content" => []}).usage

      assert usage.input_tokens == 0
      assert usage.output_tokens == 0

      for key <- [:cache_creation, :service_tier, :inference_geo, :speed] do
        assert Map.fetch!(usage, key) == nil
      end
    end
  end

  describe "from_map/1 diagnostics" do
    @miss %{
      "cache_miss_reason" => %{"type" => "system_changed", "cache_missed_input_tokens" => 41_850}
    }

    test "kept raw, string keys" do
      assert Response.from_map(%{"content" => [], "diagnostics" => @miss}).diagnostics == @miss
    end

    test "atom keys" do
      assert Response.from_map(%{content: [], diagnostics: @miss}).diagnostics == @miss
    end

    test "nil when absent or null" do
      assert Response.from_map(%{"content" => []}).diagnostics == nil
      assert Response.from_map(%{"content" => [], "diagnostics" => nil}).diagnostics == nil
    end
  end

  describe "from_map/1 usage with mixed token-key styles" do
    test "string input_tokens + atom output_tokens is normalised, not passed through raw" do
      usage =
        Response.from_map(%{
          "content" => [],
          "usage" => %{"input_tokens" => 4, :output_tokens => 9, "inference_geo" => "us"}
        }).usage

      assert usage.input_tokens == 4
      assert usage.output_tokens == 9
      assert usage.inference_geo == "us"
      refute Map.has_key?(usage, "input_tokens")
    end

    test "a usage map missing a token count is still returned as-is" do
      assert Response.from_map(%{"content" => [], "usage" => %{"output_tokens" => 3}}).usage ==
               %{"output_tokens" => 3}
    end
  end

  # RF's documented example block (refusals-and-fallback, fetched 2026-09-25).
  @fallback_block %{
    "type" => "fallback",
    "from" => %{"model" => "claude-fable-5"},
    "to" => %{"model" => "claude-opus-4-8"}
  }

  describe "from_map/1 fallback blocks" do
    test "string-keyed block parses to a typed map that keeps the original" do
      [block] = Response.from_map(%{"content" => [@fallback_block]}).content

      assert block == %{
               type: :fallback,
               from: %{"model" => "claude-fable-5"},
               to: %{"model" => "claude-opus-4-8"},
               trigger: nil,
               raw: @fallback_block
             }
    end

    test "optional trigger is kept" do
      trigger = %{"type" => "refusal", "category" => "cyber"}

      [block] =
        Response.from_map(%{"content" => [Map.put(@fallback_block, "trigger", trigger)]}).content

      assert block.trigger == trigger
    end

    test "atom-keyed block parses too" do
      raw = %{type: "fallback", from: %{model: "a"}, to: %{model: "b"}}
      [block] = Response.from_map(%{content: [raw]}).content

      assert %{type: :fallback, from: %{model: "a"}, to: %{model: "b"}, raw: ^raw} = block
    end

    test "to_assistant_content/1 re-emits the original block, unknown sub-fields included" do
      raw = Map.put(@fallback_block, "future", %{"x" => 1})

      response =
        Response.from_map(%{
          "content" => [raw, %{"type" => "text", "text" => "Hi"}]
        })

      assert Response.to_assistant_content(response) == [
               raw,
               %{"type" => "text", "text" => "Hi"}
             ]
    end
  end

  describe "fallbacks/1" do
    test "returns [] without fallback blocks" do
      response = Response.from_map(%{"content" => [%{"type" => "text", "text" => "x"}]})
      assert Response.fallbacks(response) == []
    end

    test "returns every fallback block in content order" do
      second = %{
        "type" => "fallback",
        "from" => %{"model" => "claude-opus-4-8"},
        "to" => %{"model" => "claude-opus-5"}
      }

      response =
        Response.from_map(%{
          "content" => [
            @fallback_block,
            %{"type" => "text", "text" => "x"},
            second
          ]
        })

      assert [%{raw: @fallback_block}, %{raw: ^second}] = Response.fallbacks(response)
    end
  end

  describe "served_by/1" do
    test "is the top-level model when there is no fallback block" do
      response = Response.from_map(%{"model" => "claude-opus-5-5", "content" => []})
      assert Response.served_by(response) == "claude-opus-5-5"
    end

    test "is the last fallback block's to.model, even when model names the declining model" do
      second = %{
        "type" => "fallback",
        "from" => %{"model" => "claude-opus-4-8"},
        "to" => %{"model" => "claude-opus-5"}
      }

      response =
        Response.from_map(%{
          "model" => "claude-fable-5",
          "content" => [@fallback_block, second]
        })

      assert Response.served_by(response) == "claude-opus-5"
    end

    test "reads an atom-keyed to.model" do
      response =
        Response.from_map(%{
          model: "a",
          content: [%{type: "fallback", from: %{model: "a"}, to: %{model: "b"}}]
        })

      assert Response.served_by(response) == "b"
    end

    test "falls back to model when the block has no to.model" do
      response =
        Response.from_map(%{"model" => "m", "content" => [%{"type" => "fallback"}]})

      assert Response.served_by(response) == "m"
    end
  end
end
