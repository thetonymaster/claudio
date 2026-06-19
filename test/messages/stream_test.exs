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
end
