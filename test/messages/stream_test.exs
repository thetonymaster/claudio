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
end
