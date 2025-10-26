Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.Messages.StreamingIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Claudio.Messages
  alias Claudio.Messages.{Request, Stream}

  setup_all do
    case skip_if_no_api_key() do
      :ok ->
        client = create_client()
        {:ok, %{client: client}}

      {:skip, reason} ->
        {:skip, reason}
    end
  end

  describe "streaming messages" do
    test "streams text chunks", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Count from 1 to 5")
        |> Request.set_max_tokens(100)
        |> Request.enable_streaming()

      assert {:ok, stream_response} = Messages.create(client, request)

      text_chunks =
        stream_response.body
        |> Stream.parse_events()
        |> Stream.accumulate_text()
        |> Enum.to_list()

      assert length(text_chunks) > 0
      full_text = Enum.join(text_chunks, "")
      assert String.length(full_text) > 0
    end

    test "parses all event types", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Say hello")
        |> Request.set_max_tokens(50)
        |> Request.enable_streaming()

      assert {:ok, stream_response} = Messages.create(client, request)

      events =
        stream_response.body
        |> Stream.parse_events()
        |> Enum.to_list()

      event_types =
        events
        |> Enum.map(fn
          {:ok, event} -> event.event
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      # Should have standard streaming events
      assert "message_start" in event_types
      assert "content_block_start" in event_types
      assert "content_block_delta" in event_types
      assert "message_delta" in event_types
      assert "message_stop" in event_types
    end

    test "filters specific event types", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Hello")
        |> Request.set_max_tokens(20)
        |> Request.enable_streaming()

      assert {:ok, stream_response} = Messages.create(client, request)

      delta_events =
        stream_response.body
        |> Stream.parse_events()
        |> Stream.filter_events(["content_block_delta"])
        |> Enum.to_list()

      assert length(delta_events) > 0

      Enum.each(delta_events, fn {:ok, event} ->
        assert event.event == "content_block_delta"
      end)
    end

    test "builds final message from stream", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Say hello in 5 words")
        |> Request.set_max_tokens(50)
        |> Request.enable_streaming()

      assert {:ok, stream_response} = Messages.create(client, request)

      assert {:ok, final_message} =
               stream_response.body
               |> Stream.parse_events()
               |> Stream.build_final_message()

      assert final_message["id"]
      assert final_message["content"]
      assert final_message["usage"]
      assert final_message["usage"]["input_tokens"] > 0
      assert final_message["usage"]["output_tokens"] > 0
    end
  end
end
