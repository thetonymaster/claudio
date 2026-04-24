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
end
