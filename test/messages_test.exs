defmodule Claudio.MessagesTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request

  setup do
    # Create a client with Req.Test adapter for testing
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{
          token: "fake-token",
          version: "2023-06-01",
          beta: ["token-counting-2024-11-01"]
        },
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  test "messages success", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "content" => [
            %{
              "text" => "Hi! Nice to meet you. How can I help you today?",
              "type" => "text"
            }
          ],
          "id" => "msg_016DmRZcBG7dB9ohnwhV3wmQ",
          "model" => "claude-3-5-sonnet-20241022",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "stop_sequence" => nil,
          "type" => "message",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 17}
        })
      )
    end)

    assert {:ok, response} =
             Claudio.Messages.create_message(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "max_tokens" => 1024,
               "messages" => [%{"role" => "user", "content" => "Hello, world"}]
             })

    assert Map.get(response, "id") == "msg_016DmRZcBG7dB9ohnwhV3wmQ"
  end

  test "message fail", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        401,
        Jason.encode!(%{
          "error" => %{
            "message" => "messages: Input should be a valid list",
            "type" => "invalid_request_error"
          },
          "type" => "error"
        })
      )
    end)

    assert {:error, _} =
             Claudio.Messages.create_message(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "max_tokens" => 1024,
               "messages" => %{"role" => "user", "content" => "Hello, world"}
             })
  end

  test "count tokens", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"input_tokens" => 10}))
    end)

    assert {:ok, _} =
             Claudio.Messages.count_tokens(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "messages" => [%{"role" => "user", "content" => "Hello, world"}]
             })
  end

  test "count tokens fail", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        401,
        Jason.encode!(%{
          "error" => %{
            "message" => "messages.0.max-tokens: Extra inputs are not permitted",
            "type" => "invalid_request_error"
          },
          "type" => "error"
        })
      )
    end)

    assert {:error, _} =
             Claudio.Messages.count_tokens(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "messages" => [
                 %{"role" => "user", "content" => "Hello, world", "max-tokens": 1024}
               ]
             })
  end

  # Regression: `Req.post(... into: :self)` leaves the response body on the
  # mailbox. For non-200 responses the body used to be discarded, which
  # surfaced as `%APIError{raw_body: nil}` and hid the real Anthropic error
  # message (e.g. "unexpected tool_use_id"). `drain_async_body/1` now pulls
  # the body off the mailbox before constructing the APIError.
  test "streaming 400 surfaces the Anthropic error body (not nil)", %{
    client: client,
    bypass: bypass
  } do
    error_body = %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" =>
          "messages.2.content.0: unexpected tool_use_id found in tool_result blocks: toolu_regression"
      }
    }

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(400, Jason.encode!(error_body))
    end)

    request =
      Claudio.Messages.Request.new("claude-3-5-sonnet-20241022")
      |> Claudio.Messages.Request.add_message(:user, "Hello")
      |> Claudio.Messages.Request.set_max_tokens(64)
      |> Claudio.Messages.Request.enable_streaming()

    assert {:error, %Claudio.APIError{} = err} = Claudio.Messages.create(client, request)
    assert err.status_code == 400
    assert is_map(err.raw_body), "raw_body must be a decoded map, not nil"
    assert err.message =~ "unexpected tool_use_id"
    assert err.type == :invalid_request_error

    # Extra: the drained body must round-trip the original error payload.
    assert get_in(err.raw_body, ["error", "type"]) == "invalid_request_error"
  end

  # Regression: the 2s overall deadline must outlast idle gaps between chunks.
  # An earlier version of `drain_loop/3` decoded after the first 200ms of
  # mailbox silence, which truncated slow/chunked error bodies and recreated
  # the original `%APIError{raw_body: nil}` bug. This test sends the 400 body
  # in two chunks with a 250ms sleep between them — longer than the idle
  # window, well under the deadline — and asserts the full body is captured.
  test "streaming 400 survives chunked/delayed body across the idle window", %{
    client: client,
    bypass: bypass
  } do
    error_body = %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" =>
          "messages.2.content.0: unexpected tool_use_id found in tool_result blocks: toolu_regression"
      }
    }

    encoded = Jason.encode!(error_body)
    half = div(byte_size(encoded), 2)
    <<first::binary-size(half), second::binary>> = encoded

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_chunked(400)

      {:ok, conn} = Plug.Conn.chunk(conn, first)
      :timer.sleep(250)
      {:ok, conn} = Plug.Conn.chunk(conn, second)
      conn
    end)

    request =
      Claudio.Messages.Request.new("claude-3-5-sonnet-20241022")
      |> Claudio.Messages.Request.add_message(:user, "Hello")
      |> Claudio.Messages.Request.set_max_tokens(64)
      |> Claudio.Messages.Request.enable_streaming()

    assert {:error, %Claudio.APIError{} = err} = Claudio.Messages.create(client, request)
    assert err.status_code == 400
    assert is_map(err.raw_body), "raw_body must be a decoded map, not nil"
    assert err.message =~ "unexpected tool_use_id"
    assert err.type == :invalid_request_error
    assert get_in(err.raw_body, ["error", "type"]) == "invalid_request_error"
  end

  # Regression: `drain_loop/4` must not silently consume mailbox messages that
  # don't belong to Req. If the caller is a GenServer, a cast/call/monitor
  # message arriving during the drain has to survive — otherwise the drain
  # trades one lost-data bug (raw_body: nil) for another (lost caller msgs).
  # `replay_unknown/1` re-delivers buffered `:unknown` messages to self() in
  # arrival order before returning.
  test "streaming 400 drain preserves unrelated mailbox messages", %{
    client: client,
    bypass: bypass
  } do
    error_body = %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "message" => "bad"
      }
    }

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(400, Jason.encode!(error_body))
    end)

    # Seed the mailbox with a sentinel BEFORE calling create/2. During the
    # drain, Req.parse_message/2 classifies this as :unknown. The old code
    # dropped it; the fix buffers and replays it.
    send(self(), {:sentinel, :from_test})
    send(self(), {:sentinel, :second})

    request =
      Claudio.Messages.Request.new("claude-3-5-sonnet-20241022")
      |> Claudio.Messages.Request.add_message(:user, "Hello")
      |> Claudio.Messages.Request.set_max_tokens(64)
      |> Claudio.Messages.Request.enable_streaming()

    assert {:error, %Claudio.APIError{status_code: 400}} =
             Claudio.Messages.create(client, request)

    # Both sentinels must still be deliverable, and in arrival order.
    assert_received {:sentinel, :from_test}
    assert_received {:sentinel, :second}
  end

  test "telemetry stop metadata includes token usage for non-streaming success", %{
    client: client,
    bypass: bypass
  } do
    model = unique_model("non-streaming-success")

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "id" => "msg_telemetry_success",
          "model" => model,
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "stop_sequence" => nil,
          "type" => "message",
          "usage" => %{
            "input_tokens" => 123,
            "output_tokens" => 45,
            "cache_creation_input_tokens" => 10,
            "cache_read_input_tokens" => 5
          }
        })
      )
    end)

    attach_telemetry_handler(
      [:claudio, :messages, :create, :stop],
      fn metadata -> metadata.model == model end
    )

    request =
      Request.new(model)
      |> Request.add_message(:user, "hello")
      |> Request.set_max_tokens(64)

    assert {:ok, _response} = Claudio.Messages.create(client, request)

    assert_receive {:telemetry_event, [:claudio, :messages, :create, :stop], metadata}

    assert metadata.status == :ok
    assert metadata.input_tokens == 123
    assert metadata.output_tokens == 45
    assert metadata.cache_creation_input_tokens == 10
    assert metadata.cache_read_input_tokens == 5
  end

  test "telemetry stop metadata omits token usage for non-streaming error", %{
    client: client,
    bypass: bypass
  } do
    model = unique_model("non-streaming-error")

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        401,
        Jason.encode!(%{
          "error" => %{
            "message" => "Unauthorized",
            "type" => "authentication_error"
          },
          "type" => "error"
        })
      )
    end)

    attach_telemetry_handler(
      [:claudio, :messages, :create, :stop],
      fn metadata -> metadata.model == model end
    )

    request =
      Request.new(model)
      |> Request.add_message(:user, "hello")
      |> Request.set_max_tokens(64)

    assert {:error, _reason} = Claudio.Messages.create(client, request)

    assert_receive {:telemetry_event, [:claudio, :messages, :create, :stop], metadata}

    assert metadata.status == :error
    assert is_binary(metadata.error)
    refute Map.has_key?(metadata, :input_tokens)
    refute Map.has_key?(metadata, :output_tokens)
    refute Map.has_key?(metadata, :cache_creation_input_tokens)
    refute Map.has_key?(metadata, :cache_read_input_tokens)
  end

  test "streaming emits final usage telemetry event when stream is consumed", %{
    client: client,
    bypass: bypass
  } do
    model = unique_model("streaming-usage")

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      sse =
        [
          "event: message_start\n",
          "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"#{model}\",\"content\":[]}}\n\n",
          "event: message_delta\n",
          "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null,\"stop_sequence\":null},\"usage\":{\"input_tokens\":123,\"output_tokens\":45,\"cache_creation_input_tokens\":10,\"cache_read_input_tokens\":5}}\n\n",
          "event: message_stop\n",
          "data: {\"type\":\"message_stop\"}\n\n"
        ]
        |> IO.iodata_to_binary()

      {:ok, conn} = Plug.Conn.chunk(conn, sse)
      conn
    end)

    attach_telemetry_handler([:claudio, :messages, :stream, :usage])

    request =
      Request.new(model)
      |> Request.add_message(:user, "hello")
      |> Request.set_max_tokens(64)
      |> Request.enable_streaming()

    assert {:ok, stream_response} = Claudio.Messages.create(client, request)

    _events =
      stream_response.body
      |> Claudio.Messages.Stream.parse_events()
      |> Enum.to_list()

    assert_receive {:telemetry_event, [:claudio, :messages, :stream, :usage], metadata}

    assert metadata.input_tokens == 123
    assert metadata.output_tokens == 45
    assert metadata.cache_creation_input_tokens == 10
    assert metadata.cache_read_input_tokens == 5
  end

  defp attach_telemetry_handler(event_name, filter_fn \\ fn _metadata -> true end) do
    handler_id = "messages-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn name, _measurements, metadata, {pid, filter} ->
          if filter.(metadata) do
            send(pid, {:telemetry_event, name, metadata})
          end
        end,
        {test_pid, filter_fn}
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end

  defp unique_model(suffix) do
    "claude-3-5-sonnet-20241022-#{suffix}-#{System.unique_integer([:positive])}"
  end
end
