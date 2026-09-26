defmodule Claudio.Messages.StreamTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Stream, as: ClaudioStream

  describe "parse_events/1 key convention" do
    # Earlier Claudio versions decoded event data with `Poison.decode(keys: :atoms)`,
    # producing atom-keyed data maps. Downstream consumers (e.g. Normandy's
    # ClaudioAdapter) pattern-match on string keys consistent with the raw
    # Anthropic SSE payload, so atom-keyed decoding silently broke those
    # callbacks (they fell through to catch-all clauses). This regression
    # test pins the JSON-native string-key convention.
    test "emits string-keyed data maps for content_block_delta events" do
      sse_lines = [
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}),
        ""
      ]

      events =
        [Enum.join(sse_lines, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> Enum.to_list()

      assert [{:ok, event}] = events
      assert event.event == "content_block_delta"
      assert %{"type" => "content_block_delta"} = event.data
      assert %{"delta" => %{"type" => "text_delta", "text" => "hi"}} = event.data
      assert %{"index" => 0} = event.data

      # Negative assertion: atom keys MUST NOT appear in decoded data.
      refute Map.has_key?(event.data, :delta)
      refute Map.has_key?(event.data, :type)
    end

    test "emits string-keyed data maps for message_start events" do
      sse_lines = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","model":"claude-x","content":[]}}),
        ""
      ]

      events =
        [Enum.join(sse_lines, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> Enum.to_list()

      assert [{:ok, event}] = events
      assert event.event == "message_start"
      assert %{"message" => %{"id" => "msg_1", "role" => "assistant"}} = event.data
      refute Map.has_key?(event.data, :message)
    end

    test "emits string-keyed data maps for message_stop events" do
      sse_lines = [
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      events =
        [Enum.join(sse_lines, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> Enum.to_list()

      assert [{:ok, event}] = events
      assert event.event == "message_stop"
      assert %{"type" => "message_stop"} = event.data
      refute Map.has_key?(event.data, :type)
    end

    test "returns {:error, {:invalid_event_data_json, ...}} on decode failure" do
      sse_lines = [
        ~s(event: content_block_delta),
        ~s(data: {not-valid-json),
        ""
      ]

      events =
        [Enum.join(sse_lines, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> Enum.to_list()

      assert [{:error, {:invalid_event_data_json, "content_block_delta", _reason}}] = events
    end
  end

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
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"citations_delta","citation":{"type":"char_location","cited_text":"second source","document_index":1}}}),
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

      assert [
               %{
                 "type" => "text",
                 "text" => "Paris",
                 "citations" => [first_citation, second_citation]
               }
             ] =
               message["content"]

      assert %{"type" => "char_location", "cited_text" => "Paris is the capital"} = first_citation
      assert %{"type" => "char_location", "cited_text" => "second source"} = second_citation
    end
  end

  defp final_message(delta_json) do
    sse = [
      ~s(event: message_start),
      ~s(data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5","stop_reason":null,"usage":{"input_tokens":5,"output_tokens":0}}}),
      "",
      ~s(event: message_delta),
      ~s(data: {"type":"message_delta","delta":#{delta_json},"usage":{"output_tokens":3}}),
      "",
      ~s(event: message_stop),
      ~s(data: {"type":"message_stop"}),
      ""
    ]

    {:ok, message} =
      [Enum.join(sse, "\n") <> "\n"]
      |> ClaudioStream.parse_events()
      |> ClaudioStream.build_final_message()

    message
  end

  describe "build_final_message/1 stop_details" do
    test "copies stop_details from message_delta" do
      message =
        final_message(
          ~s({"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":"cyber","explanation":"declined"}})
        )

      assert message["stop_reason"] == "refusal"

      assert message["stop_details"] == %{
               "type" => "refusal",
               "category" => "cyber",
               "explanation" => "declined"
             }
    end

    test "absent stop_details leaves the key off" do
      message = final_message(~s({"stop_reason":"end_turn","stop_sequence":null}))
      refute Map.has_key?(message, "stop_details")
    end
  end

  describe "build_final_message/1 usage merge" do
    test "message_delta usage merges over message_start usage (input_tokens survive)" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":2,"output_tokens":1}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3,"output_tokens_details":{"thinking_tokens":2}}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      assert message["usage"] == %{
               "input_tokens" => 5,
               "cache_read_input_tokens" => 2,
               "output_tokens" => 3,
               "output_tokens_details" => %{"thinking_tokens" => 2}
             }

      usage = Claudio.Messages.Response.from_map(message).usage
      assert usage.input_tokens == 5
      assert usage.output_tokens == 3
      assert usage.output_tokens_details == %{"thinking_tokens" => 2}
    end
  end

  describe "build_final_message/1 usage merge with mixed key styles" do
    test "delta wins when message_start usage is atom-keyed and delta usage string-keyed" do
      events = [
        {:ok,
         %{
           event: "message_start",
           data: %{
             "message" => %{
               "id" => "m",
               "content" => [],
               "usage" => %{input_tokens: 5, output_tokens: 1}
             }
           }
         }},
        {:ok,
         %{
           event: "message_delta",
           data: %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 3}}
         }},
        {:ok, %{event: "message_stop", data: %{}}}
      ]

      {:ok, message} = ClaudioStream.build_final_message(events)

      assert message["usage"] == %{"input_tokens" => 5, "output_tokens" => 3}
      assert Claudio.Messages.Response.from_map(message).usage.output_tokens == 3
    end
  end

  describe "output_tokens_details through build_final_message/1 → Response.from_map/1" do
    test "final message_delta usage details survive into the parsed Response" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","stop_reason":null,"usage":{"input_tokens":5,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":5,"output_tokens":40,"output_tokens_details":{"thinking_tokens":25}}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      response = Claudio.Messages.Response.from_map(message)
      assert response.usage.output_tokens_details == %{"thinking_tokens" => 25}
    end
  end

  describe "accumulate_thinking/1" do
    test "emits {index, text} for non-empty thinking deltas only" do
      sse = [
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"b"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"s0"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"hello"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":3,"delta":{"type":"thinking_delta","thinking":"c"}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      result =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.accumulate_thinking()
        |> Enum.to_list()

      assert result == [{0, "a"}, {0, "b"}, {3, "c"}]
    end

    test "atom-keyed event data works too" do
      events = [
        {:ok,
         %{
           event: "content_block_delta",
           data: %{index: 4, delta: %{type: "thinking_delta", thinking: "x"}}
         }}
      ]

      assert events |> ClaudioStream.accumulate_thinking() |> Enum.to_list() == [{4, "x"}]
    end

    test "a thinking delta without an index keeps its text, as {nil, text}" do
      events = [
        {:ok,
         %{
           event: "content_block_delta",
           data: %{"delta" => %{"type" => "thinking_delta", "thinking" => "z"}}
         }}
      ]

      assert events |> ClaudioStream.accumulate_thinking() |> Enum.to_list() == [{nil, "z"}]
    end

    test "error items and other events are skipped, not raised on" do
      events = [
        {:error, :boom},
        {:ok, %{event: "ping", data: %{}}},
        {:ok,
         %{
           event: "content_block_delta",
           data: %{"index" => 0, "delta" => %{"type" => "thinking_delta", "thinking" => "y"}}
         }}
      ]

      assert events |> ClaudioStream.accumulate_thinking() |> Enum.to_list() == [{0, "y"}]
    end
  end

  describe "diagnostics through build_final_message/1 → Response.from_map/1" do
    test "diagnostics on message_start survive into the parsed Response" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","diagnostics":{"cache_miss_reason":null},"usage":{"input_tokens":5,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      assert Claudio.Messages.Response.from_map(message).diagnostics == %{
               "cache_miss_reason" => nil
             }
    end
  end

  describe "build_final_message/1 mid-output fallback" do
    # RF "Streaming": on a mid-output decline the fallback block is a
    # content_block_start/stop pair with no deltas; message_start named the
    # requested model, so the serving model is read from the block's to.model.
    test "the no-delta fallback block survives and parses into the Response" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":1}}}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Part"}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":0}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":1}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Hello"}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":2}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3,"iterations":[{"type":"message","model":"claude-opus-5-5","input_tokens":5,"output_tokens":1},{"type":"fallback_message","model":"claude-opus-4-8","input_tokens":7,"output_tokens":3}]}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      # RF: the serving model is also in the final message_delta's usage.iterations.
      assert [
               %{"type" => "message"},
               %{"type" => "fallback_message", "model" => "claude-opus-4-8"}
             ] =
               message["usage"]["iterations"]

      response = Claudio.Messages.Response.from_map(message)

      assert [%{type: :text, text: "Part"}, %{type: :fallback}, %{type: :text, text: "Hello"}] =
               response.content

      assert response.model == "claude-opus-5-5"
      assert Claudio.Messages.Response.served_by(response) == "claude-opus-4-8"
      assert [_, %{"type" => "fallback_message"}] = response.usage.iterations
    end
  end

  describe "build_final_message/1 threshold compaction" do
    test "compaction_delta fills the block; context_management and stop_reason survive" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":0,"output_tokens":0},"diagnostics":null,"context_management":null}}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"compaction","content":null}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"compaction_delta","content":"Summary of the session."}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":0}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"compaction","stop_sequence":null,"stop_details":null,"container":null},"usage":{"input_tokens":0,"output_tokens":0,"iterations":[{"type":"compaction","input_tokens":54453,"output_tokens":883}]},"context_management":{"applied_edits":[]}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      assert message["content"] == [
               %{"type" => "compaction", "content" => "Summary of the session."}
             ]

      assert message["context_management"] == %{"applied_edits" => []}

      response = Claudio.Messages.Response.from_map(message)

      assert response.stop_reason == :compaction
      assert response.context_management == %{"applied_edits" => []}
      assert [%{type: :compaction, content: "Summary of the session."}] = response.content
      assert [%{"type" => "compaction"}] = response.usage.iterations

      # Review Focus 3: the streamed block replays byte-exact.
      assert Claudio.Messages.Response.to_assistant_content(response) == [
               %{"type" => "compaction", "content" => "Summary of the session."}
             ]
    end

    test "atom-keyed event data: compaction_delta still fills the block" do
      events = [
        {:ok,
         %{
           event: "content_block_start",
           data: %{index: 0, content_block: %{type: "compaction", content: nil}}
         }},
        {:ok,
         %{
           event: "content_block_delta",
           data: %{index: 0, delta: %{type: "compaction_delta", content: "S"}}
         }},
        {:ok, %{event: "content_block_stop", data: %{index: 0}}}
      ]

      assert {:ok, %{"content" => [%{type: "compaction", content: "S"}]}} =
               ClaudioStream.build_final_message(events)
    end

    test "on-demand: a whole signed block in content_block_start, no deltas (spec F14)" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","content":[],"model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0}}}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"compaction","content":"Sum.","signature":"sig"}}),
        "",
        ~s(event: ping),
        ~s(data: {"type":"ping"}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":0}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"compaction"},"usage":{"output_tokens":0}}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      response = Claudio.Messages.Response.from_map(message)

      # Byte-exact, signature included — what apply_compaction/2 (Task 4) replays.
      assert response.stop_reason == :compaction

      assert Claudio.Messages.Response.to_assistant_content(response) == [
               %{"type" => "compaction", "content" => "Sum.", "signature" => "sig"}
             ]
    end

    test "a message_delta without context_management keeps the message_start value" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","content":[],"model":"x","context_management":{"applied_edits":[]},"usage":{"input_tokens":1,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      assert message["context_management"] == %{"applied_edits" => []}
    end
  end

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

  describe "build_final_message/1 input_transformations (S15)" do
    @start_entry ~s([{"type":"thinking_dropped","path":"messages.1.content.0","reason":"prefix_binding_mismatch"}])

    defp binding_stream(delta_event) do
      [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","content":[],"model":"x","input_transformations":#{@start_entry},"usage":{"input_tokens":1,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        "data: " <> delta_event,
        ""
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> List.wrap()
      |> ClaudioStream.parse_events()
      |> ClaudioStream.build_final_message()
    end

    test "message_start value survives a delta without the key (Review Focus 4)" do
      {:ok, message} =
        binding_stream(
          ~s({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}})
        )

      assert [%{"type" => "thinking_dropped"}] =
               Claudio.Messages.Response.from_map(message).input_transformations
    end

    test "a top-level key on message_delta replaces it (post-fallback copy)" do
      {:ok, message} =
        binding_stream(
          ~s({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1},"input_transformations":[]})
        )

      assert message["input_transformations"] == []
    end

    # The SDK types input_transformations as a field of the message_delta event, not of
    # its delta (anthropic-sdk-python BetaRawMessageDeltaEvent, checked 2026-09-26).
    test "a key inside delta is ignored: only the event's top level carries it" do
      {:ok, message} =
        binding_stream(
          ~s({"type":"message_delta","delta":{"stop_reason":"end_turn","input_transformations":[]},"usage":{"output_tokens":1}})
        )

      assert [%{"type" => "thinking_dropped"}] = message["input_transformations"]
    end
  end
end
