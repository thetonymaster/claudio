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
               speed: nil,
               iterations: nil
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
               input: %{"query" => "elixir"},
               caller: nil
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
               content: @web_results,
               caller: nil,
               raw: hd(data["content"])
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
      # Dynamic-filtering web_search returns code_execution_tool_result blocks, which
      # are typed shallowly since S14; getters must still not crash on mixed content.
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
            "future_field" => [%{"type" => "message"}]
          }
        }).usage

      assert string_keyed["future_field"] == [%{"type" => "message"}]

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

    test "iterations becomes an atom key with raw entries (RF example)" do
      iterations = [
        %{
          "type" => "message",
          "model" => "claude-fable-5",
          "input_tokens" => 535,
          "output_tokens" => 0,
          "cache_read_input_tokens" => 0,
          "cache_creation_input_tokens" => 0
        },
        %{
          "type" => "fallback_message",
          "model" => "claude-opus-4-8",
          "input_tokens" => 412,
          "output_tokens" => 264,
          "cache_read_input_tokens" => 0,
          "cache_creation_input_tokens" => 0
        }
      ]

      usage =
        Response.from_map(%{
          "content" => [],
          "usage" => %{"input_tokens" => 412, "output_tokens" => 264, "iterations" => iterations}
        }).usage

      assert usage.iterations == iterations
      refute Map.has_key?(usage, "iterations")
    end

    test "nil usage has the new keys as nil" do
      usage = Response.from_map(%{"content" => []}).usage

      assert usage.input_tokens == 0
      assert usage.output_tokens == 0

      for key <- [:cache_creation, :service_tier, :inference_geo, :speed, :iterations] do
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

  describe "from_map/1 compaction blocks" do
    @signed %{"type" => "compaction", "content" => "Summary.", "signature" => "sig"}

    test "string keys parse to a typed block that keeps the original under raw" do
      response = Response.from_map(%{"content" => [@signed], "stop_reason" => "compaction"})

      assert response.stop_reason == :compaction
      assert [%{type: :compaction, content: "Summary.", raw: @signed}] = response.content
    end

    test "atom keys" do
      raw = %{type: "compaction", content: "Summary."}
      response = Response.from_map(%{content: [raw]})

      assert [%{type: :compaction, content: "Summary.", raw: ^raw}] = response.content
    end

    test "content: nil (a failed compaction) parses" do
      response = Response.from_map(%{"content" => [%{"type" => "compaction", "content" => nil}]})
      assert [%{type: :compaction, content: nil}] = response.content
    end

    test "to_assistant_content/1 replays the block byte-exact, signature included" do
      block = Map.put(@signed, "encrypted_content", "enc")

      response =
        Response.from_map(%{
          "content" => [block, %{"type" => "text", "text" => "Hi"}]
        })

      assert Response.to_assistant_content(response) == [
               block,
               %{"type" => "text", "text" => "Hi"}
             ]
    end
  end

  describe "compaction_block/1" do
    test "nil without a compaction block" do
      assert Response.compaction_block(Response.from_map(%{"content" => []})) == nil
    end

    test "returns the last compaction block" do
      response =
        Response.from_map(%{
          "content" => [
            %{"type" => "compaction", "content" => "first"},
            %{"type" => "text", "text" => "x"},
            %{"type" => "compaction", "content" => "second"}
          ]
        })

      assert %{type: :compaction, content: "second"} = Response.compaction_block(response)
    end
  end

  describe "from_map/1 context_management" do
    @applied %{
      "applied_edits" => [
        %{
          "type" => "clear_tool_uses_20250919",
          "cleared_tool_uses" => 2,
          "cleared_input_tokens" => 900
        }
      ]
    }

    test "kept raw, string and atom keys" do
      assert Response.from_map(%{"content" => [], "context_management" => @applied}).context_management ==
               @applied

      assert Response.from_map(%{content: [], context_management: @applied}).context_management ==
               @applied
    end

    test "nil when absent" do
      assert Response.from_map(%{"content" => []}).context_management == nil
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

  defp fb(from, to) do
    %{"type" => "fallback", "from" => %{"model" => from}, "to" => %{"model" => to}}
  end

  defp content(blocks), do: Response.from_map(%{"content" => blocks})

  describe "to_assistant_content/1 continuation rules after a fallback" do
    # RF "Continuing the conversation" (fetched 2026-09-25); mcp_tool_use follows the
    # server_tool_use pairing rule (spec §3, probes P12b/P13).
    test "no fallback block: unchanged, thinking and tool_use included" do
      blocks = [
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
        %{"type" => "text", "text" => "a"}
      ]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "fallback first (every non-streaming response): unchanged" do
      blocks = [
        fb("claude-fable-5", "claude-opus-4-8"),
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
        %{"type" => "text", "text" => "a"}
      ]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "mid-output fallback: drops and pairing apply before it, everything after is kept" do
      paired_srv = %{
        "type" => "server_tool_use",
        "id" => "srv_1",
        "name" => "web_search",
        "input" => %{}
      }

      srv_result = %{
        "type" => "web_search_tool_result",
        "tool_use_id" => "srv_1",
        "content" => []
      }

      unpaired_srv = %{
        "type" => "server_tool_use",
        "id" => "srv_2",
        "name" => "web_search",
        "input" => %{}
      }

      paired_mcp = %{
        "type" => "mcp_tool_use",
        "id" => "mcp_1",
        "name" => "x",
        "server_name" => "s",
        "input" => %{}
      }

      mcp_result = %{
        "type" => "mcp_tool_result",
        "tool_use_id" => "mcp_1",
        "server_name" => "s",
        "content" => [],
        "is_error" => false
      }

      unpaired_mcp = %{paired_mcp | "id" => "mcp_2"}
      unknown = %{"type" => "container_upload", "file_id" => "file_1"}
      fallback = fb("claude-opus-5-5", "claude-opus-4-8")
      after_tool_use = %{"type" => "tool_use", "id" => "toolu_9", "name" => "x", "input" => %{}}

      blocks = [
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "redacted_thinking", "data" => "enc"},
        %{"type" => "connector_text", "text" => "narration"},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
        paired_srv,
        srv_result,
        unpaired_srv,
        paired_mcp,
        mcp_result,
        unpaired_mcp,
        %{"type" => "text", "text" => "partial"},
        unknown,
        fallback,
        %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
        %{"type" => "text", "text" => "Hello"},
        after_tool_use
      ]

      assert Response.to_assistant_content(content(blocks)) == [
               paired_srv,
               srv_result,
               paired_mcp,
               mcp_result,
               %{"type" => "text", "text" => "partial"},
               unknown,
               fallback,
               %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
               %{"type" => "text", "text" => "Hello"},
               after_tool_use
             ]
    end

    test "a result after the fallback still pairs a server_tool_use before it" do
      srv = %{"type" => "server_tool_use", "id" => "srv_1", "name" => "web_fetch", "input" => %{}}
      result = %{"type" => "web_fetch_tool_result", "tool_use_id" => "srv_1", "content" => %{}}
      blocks = [%{"type" => "text", "text" => "a"}, srv, fb("a", "b"), result]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "two fallback blocks: rules apply only before the last one" do
      first = fb("claude-opus-5-5", "claude-opus-4-8")
      last = fb("claude-opus-4-8", "claude-opus-5")

      blocks = [
        %{"type" => "text", "text" => "a"},
        first,
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "text", "text" => "b"},
        last,
        %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
        %{"type" => "text", "text" => "c"}
      ]

      assert Response.to_assistant_content(content(blocks)) == [
               %{"type" => "text", "text" => "a"},
               first,
               %{"type" => "text", "text" => "b"},
               last,
               %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
               %{"type" => "text", "text" => "c"}
             ]
    end

    test "non-map entries pass through without crashing the filter" do
      blocks = [
        "stray",
        %{"type" => "text", "text" => "a"},
        fb("a", "b"),
        %{"type" => "text", "text" => "b"}
      ]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "atom-keyed blocks before the fallback are dropped by the same rules" do
      fallback = %{type: "fallback", from: %{model: "a"}, to: %{model: "b"}}

      response =
        Response.from_map(%{
          content: [
            %{type: :connector_text, text: "atom-valued type"},
            %{type: "server_tool_use", id: "srv_unpaired", name: "web_fetch", input: %{}},
            %{type: "thinking", thinking: "t", signature: "s"},
            %{type: "text", text: "p"},
            fallback
          ]
        })

      assert Response.to_assistant_content(response) == [
               %{"type" => "text", "text" => "p"},
               fallback
             ]
    end

    test "atom-keyed input follows the same rules" do
      fallback = %{type: "fallback", from: %{model: "a"}, to: %{model: "b"}}
      connector = %{type: "connector_text", text: "narration"}
      srv = %{type: "server_tool_use", id: "srv_1", name: "web_fetch", input: %{}}
      result = %{type: "web_fetch_tool_result", tool_use_id: "srv_1", content: %{}}

      response =
        Response.from_map(%{
          content: [connector, srv, result, %{type: "text", text: "p"}, fallback]
        })

      assert Response.to_assistant_content(response) == [
               %{
                 "type" => "server_tool_use",
                 "id" => "srv_1",
                 "name" => "web_fetch",
                 "input" => %{}
               },
               result,
               %{"type" => "text", "text" => "p"},
               fallback
             ]
    end
  end

  describe "get_tool_uses/1 after a fallback" do
    test "skips tool_use blocks before the last fallback block" do
      response =
        content([
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
          fb("a", "b"),
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "y", "input" => %{}}
        ])

      assert [%{id: "toolu_2"}] = Response.get_tool_uses(response)
    end

    test "without a fallback block every tool_use is returned" do
      response =
        content([
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "y", "input" => %{}}
        ])

      assert [%{id: "toolu_1"}, %{id: "toolu_2"}] = Response.get_tool_uses(response)
    end
  end

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
               %{
                 "type" => "server_tool_use",
                 "id" => "srv_1",
                 "name" => "web_search",
                 "input" => %{}
               },
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

      atom = %{
        type: "tool_use",
        id: "t",
        name: "left_click",
        input: %{},
        toolset_name: "computer"
      }

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

    test "typed result blocks without a raw map replay rebuilt, not as nil" do
      response = %Response{
        content: [
          %{
            type: :code_execution_tool_result,
            tool_use_id: "s",
            content: %{},
            caller: nil,
            raw: nil
          },
          %{type: :container_upload, file_id: "f", raw: nil}
        ]
      }

      assert Response.to_assistant_content(response) == [
               %{"type" => "code_execution_tool_result", "tool_use_id" => "s", "content" => %{}},
               %{"type" => "container_upload", "file_id" => "f"}
             ]
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
            %{
              "type" => "server_tool_use",
              "id" => "a",
              "name" => "code_execution",
              "input" => %{}
            },
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

  describe "from_map/1 input_transformations (S15)" do
    @dropped [
      %{
        "type" => "thinking_dropped",
        "path" => "messages.1.content.0",
        "reason" => "prefix_binding_mismatch"
      }
    ]

    test "kept raw: one entry, empty list, atom top-level key" do
      assert Response.from_map(%{"content" => [], "input_transformations" => @dropped}).input_transformations ==
               @dropped

      assert Response.from_map(%{"content" => [], "input_transformations" => []}).input_transformations ==
               []

      assert Response.from_map(%{content: [], input_transformations: @dropped}).input_transformations ==
               @dropped
    end

    test "nil when absent — the beta was not sent (Review Focus 5)" do
      assert Response.from_map(%{"content" => []}).input_transformations == nil
    end
  end
end
