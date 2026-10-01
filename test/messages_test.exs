Code.require_file("telemetry_helper.exs", __DIR__)

defmodule Claudio.MessagesTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  import Claudio.TelemetryTestSupport, only: [attach: 1]

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

  test "an HTML error page from a proxy is an APIError, not a crash", %{
    client: client,
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(502, "<html>Bad Gateway</html>")
    end)

    request = Request.new("m") |> Request.add_message(:user, "hi") |> Request.set_max_tokens(8)

    assert {:error, %Claudio.APIError{status_code: 502, type: :api_error}} =
             Claudio.Messages.create(client, request)
  end

  test "a 200 whose body is not a JSON object is an APIError, not a crash", %{
    client: client,
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.resp(200, "ok")
    end)

    request = Request.new("m") |> Request.add_message(:user, "hi") |> Request.set_max_tokens(8)

    assert {:error, %Claudio.APIError{status_code: 200}} =
             Claudio.Messages.create(client, request)
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
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Hello")
      |> Request.set_max_tokens(64)
      |> Request.enable_streaming()

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
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Hello")
      |> Request.set_max_tokens(64)
      |> Request.enable_streaming()

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
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Hello")
      |> Request.set_max_tokens(64)
      |> Request.enable_streaming()

    assert {:error, %Claudio.APIError{status_code: 400}} =
             Claudio.Messages.create(client, request)

    # Both sentinels must still be deliverable, and in arrival order.
    assert_received {:sentinel, :from_test}
    assert_received {:sentinel, :second}
  end

  # Regression: a drain that hits its 2s deadline must cancel the async response,
  # or chunks arriving after create/2 returns land in the caller's mailbox. A raw TCP
  # server: Bypass/Cowboy kills a handler whose client hung up and re-raises that exit.
  test "streaming 400 drain cancels the response at the deadline (no late chunks)" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        first = ~s({"type":"error",)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 400 Bad Request\r\ncontent-type: application/json\r\n" <>
              "transfer-encoding: chunked\r\n\r\n" <> chunk(first)
          )

        :timer.sleep(2_600)
        # The client has cancelled by now; the write may fail.
        _ = :gen_tcp.send(socket, chunk(~s("error":{"type":"x","message":"late"}})))
        :gen_tcp.close(socket)
      end)

    client = Claudio.Client.new(%{token: "t", version: "2023-06-01"}, "http://localhost:#{port}/")

    request =
      Request.new("x")
      |> Request.add_message(:user, "Hello")
      |> Request.set_max_tokens(8)
      |> Request.enable_streaming()

    assert {:error, %Claudio.APIError{status_code: 400}} =
             Claudio.Messages.create(client, request)

    Task.await(server, 5_000)
    :gen_tcp.close(listen)
    refute_receive _, 500
  end

  defp chunk(data), do: Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"

  # Regression: a transport error while draining ends the drain at once instead of
  # being ignored until the 2s deadline.
  # (A server that dies mid-body ends the stream with :done, not an error; a receive
  # timeout is what delivers `{:error, _}`.)
  test "streaming 400 drain stops on a stream error", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      # The client times out mid-handler; see the test above.
      Process.flag(:trap_exit, true)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_chunked(400)

      {:ok, conn} = Plug.Conn.chunk(conn, ~s({"type":"error",))
      :timer.sleep(1_500)
      conn
    end)

    client =
      Claudio.Client.new(
        %{token: "t", version: "2023-06-01", recv_timeout: 300},
        "http://localhost:#{bypass.port}/"
      )

    request =
      Request.new("x")
      |> Request.add_message(:user, "Hello")
      |> Request.set_max_tokens(8)
      |> Request.enable_streaming()

    {micros, result} = :timer.tc(fn -> Claudio.Messages.create(client, request) end)

    assert {:error, %Claudio.APIError{status_code: 400}} = result
    assert micros < 1_500_000, "drain took #{div(micros, 1000)}ms"
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
    refute Map.has_key?(metadata, :thinking_tokens)
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

    attach_telemetry_handler(
      [:claudio, :messages, :stream, :usage],
      fn metadata -> metadata[:input_tokens] == 123 end
    )

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
    refute Map.has_key?(metadata, :thinking_tokens)
  end

  test "telemetry stop metadata includes thinking_tokens when usage reports them", %{
    client: client,
    bypass: bypass
  } do
    model = unique_model("thinking-tokens")

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "id" => "msg_thinking_tokens",
          "model" => model,
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "stop_sequence" => nil,
          "type" => "message",
          "usage" => %{
            "input_tokens" => 12,
            "output_tokens" => 80,
            "output_tokens_details" => %{"thinking_tokens" => 64}
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
    assert metadata.thinking_tokens == 64
    assert metadata.output_tokens == 80
  end

  test "stream usage telemetry includes thinking_tokens from the final message_delta", %{
    client: client,
    bypass: bypass
  } do
    model = unique_model("stream-thinking-tokens")

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      sse =
        [
          "event: message_start\n",
          "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_st\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"#{model}\",\"content\":[]}}\n\n",
          "event: message_delta\n",
          "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"input_tokens\":12,\"output_tokens\":80,\"output_tokens_details\":{\"thinking_tokens\":64}}}\n\n",
          "event: message_stop\n",
          "data: {\"type\":\"message_stop\"}\n\n"
        ]
        |> IO.iodata_to_binary()

      {:ok, conn} = Plug.Conn.chunk(conn, sse)
      conn
    end)

    attach_telemetry_handler(
      [:claudio, :messages, :stream, :usage],
      fn metadata -> metadata[:output_tokens] == 80 end
    )

    request =
      Request.new(model)
      |> Request.add_message(:user, "hello")
      |> Request.set_max_tokens(64)
      |> Request.enable_streaming()

    assert {:ok, stream_response} = Claudio.Messages.create(client, request)
    _events = stream_response.body |> Claudio.Messages.Stream.parse_events() |> Enum.to_list()

    assert_receive {:telemetry_event, [:claudio, :messages, :stream, :usage], metadata}
    assert metadata.thinking_tokens == 64
  end

  defp attach_telemetry_handler(event_name, filter_fn) do
    handler_id = "messages-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        &__MODULE__.forward_telemetry_event/4,
        {self(), filter_fn}
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end

  # A module function capture: telemetry logs a performance note for anonymous handlers.
  def forward_telemetry_event(name, _measurements, metadata, {pid, filter}) do
    if filter.(metadata), do: send(pid, {:telemetry_event, name, metadata})
  end

  describe "beta-header merge for %Request{}" do
    test "create/2 merges a request's declared betas into anthropic-beta",
         %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
        assert beta_header =~ "token-counting-2024-11-01"
        assert beta_header =~ "context-management-2025-06-27"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-opus-4-8",
            "stop_reason" => "end_turn",
            "stop_sequence" => nil,
            "content" => [%{"type" => "text", "text" => "ok"}],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        )
      end)

      request =
        Request.new("claude-opus-4-8")
        |> Request.add_message(:user, "hi")
        |> Request.set_max_tokens(16)
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      assert {:ok, _response} = Claudio.Messages.create(client, request)
    end

    test "count_tokens/2 merges a request's declared betas",
         %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
        [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
        assert beta_header =~ "context-management-2025-06-27"
        assert beta_header =~ "token-counting-2024-11-01"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"input_tokens" => 5}))
      end)

      request =
        Request.new("claude-opus-4-8")
        |> Request.add_message(:user, "hi")
        |> Request.set_max_tokens(16)
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      assert {:ok, %{"input_tokens" => 5}} = Claudio.Messages.count_tokens(client, request)
    end

    test "count_tokens/2 strips fields the count endpoint rejects (inference_geo, diagnostics, fallbacks)",
         %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")

        # The count endpoint needs the fast-mode beta for `speed` (probed 2026-09-25).
        status =
          if Map.has_key?(payload, "inference_geo") or Map.has_key?(payload, "diagnostics") or
               Map.has_key?(payload, "fallbacks") or
               not String.contains?(beta_header, "fast-mode-2026-02-01"),
             do: 400,
             else: 200

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          status,
          Jason.encode!(%{"input_tokens" => 5, "speed" => payload["speed"]})
        )
      end)

      request =
        Request.new("claude-opus-5-5")
        |> Request.add_message(:user, "hi")
        |> Request.set_speed(:fast)
        |> Request.set_inference_geo(:us)
        |> Request.enable_cache_diagnostics()
        |> Request.set_fallbacks(:default)

      assert {:ok, %{"input_tokens" => 5, "speed" => "fast"}} =
               Claudio.Messages.count_tokens(client, request)
    end
  end

  defp unique_model(suffix) do
    "claude-3-5-sonnet-20241022-#{suffix}-#{System.unique_integer([:positive])}"
  end

  describe "count_tokens/2 strips fields the count endpoint rejects (pre-release audit)" do
    # Live probe G1 (2026-09-26): each of these → 400 "Extra inputs are not permitted".
    @rejected ~w(temperature top_k top_p stop_sequences metadata service_tier container)

    test "Request form and raw map", %{client: client, bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/messages/count_tokens", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:count_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"input_tokens" => 5}))
      end)

      request =
        Request.new("claude-haiku-4-5")
        |> Request.add_message(:user, "hi")
        |> Request.set_temperature(0.5)
        |> Request.set_top_k(5)
        |> Request.set_top_p(0.9)
        |> Request.set_stop_sequences(["X"])
        |> Request.set_metadata(%{"user_id" => "u"})
        |> Request.set_service_tier("auto")
        |> Request.set_container("container_1")

      assert {:ok, %{"input_tokens" => 5}} = Claudio.Messages.count_tokens(client, request)
      assert_received {:count_body, body}
      assert Map.keys(body) -- ["model", "messages"] == []

      raw = Map.new(@rejected, &{&1, "x"}) |> Map.merge(%{"model" => "m", "messages" => []})
      assert {:ok, _} = Claudio.Messages.count_tokens(client, raw)
      assert_received {:count_body, raw_body}
      assert Enum.sort(Map.keys(raw_body)) == ["messages", "model"]
    end
  end

  test "re-audit: a streaming non-JSON error body is typed from the status like non-streaming", %{
    client: client,
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(503, "<html>down</html>")
    end)

    request =
      Request.new("m")
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(8)
      |> Request.enable_streaming()

    assert {:error,
            %Claudio.APIError{status_code: 503, type: :api_error, raw_body: "<html>down</html>"} =
              error} =
             Claudio.Messages.create(client, request)

    assert error.message =~ "503"
  end

  # The legacy streaming path must match create/2: a retried `into: :self` request
  # leaves the failed attempt's body messages in the caller's mailbox, and a non-200
  # body sits on the mailbox rather than in `resp.body`.
  test "legacy streaming create_message/2 is not retried and surfaces the error body", %{
    bypass: bypass
  } do
    count = :counters.new(1, [:atomics])

    Bypass.expect(bypass, "POST", "/messages", fn conn ->
      :counters.add(count, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        503,
        Jason.encode!(%{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "legacy busy"}
        })
      )
    end)

    client =
      Claudio.Client.new(
        %{token: "t", version: "2023-06-01", retry: [max_retries: 2, delay: 1]},
        "http://localhost:#{bypass.port}/"
      )

    assert {:error, %Claudio.APIError{status_code: 503} = error} =
             Claudio.Messages.create_message(client, %{
               "model" => "x",
               "max_tokens" => 8,
               "stream" => true,
               "messages" => [%{"role" => "user", "content" => "hi"}]
             })

    assert error.message =~ "legacy busy"
    assert :counters.get(count, 1) == 1
    refute_receive _, 100
  end

  describe "create span (telemetry/OTel readiness)" do
    @create [
      [:claudio, :messages, :create, :start],
      [:claudio, :messages, :create, :stop],
      [:claudio, :messages, :create, :exception]
    ]

    defp json_resp(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("request-id", "req_test_1")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    defp message_body(extra \\ %{}) do
      Map.merge(
        %{
          "id" => "msg_span_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-span-model",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 11, "output_tokens" => 3}
        },
        extra
      )
    end

    defp span_request(model \\ "claude-span-model") do
      Request.new(model)
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(16)
      |> Request.set_temperature(0.5)
    end

    test "non-streaming start/stop carry request, response and token data", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)
      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, message_body()))

      assert {:ok, _} = Claudio.Messages.create(client, span_request())

      assert_receive {:telemetry, [:claudio, :messages, :create, :start], _, start}
      assert start.model == "claude-span-model"
      assert start.stream == false
      assert start.max_tokens == 16
      assert start.temperature == 0.5
      assert start.server_address == "localhost"
      assert is_reference(start.telemetry_span_context)

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements, stop}
      assert stop.telemetry_span_context == start.telemetry_span_context
      assert stop.status == :ok
      assert stop.response_id == "msg_span_1"
      assert stop.response_model == "claude-span-model"
      assert stop.stop_reason == :end_turn
      assert stop.request_id == "req_test_1"
      assert stop.input_tokens == 11
      assert measurements.input_tokens == 11
      assert measurements.output_tokens == 3
      assert is_integer(measurements.duration)
    end

    test "response_model is the fallback model that served the request", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)

      body =
        message_body(%{
          "model" => "claude-opus-5-5",
          "content" => [
            %{
              "type" => "fallback",
              "from" => %{"model" => "claude-opus-5-5"},
              "to" => %{"model" => "claude-opus-4-8"},
              "trigger" => "refusal"
            },
            %{"type" => "text", "text" => "ok"}
          ]
        })

      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, body))
      assert {:ok, _} = Claudio.Messages.create(client, span_request("claude-opus-5-5"))

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.model == "claude-opus-5-5"
      assert stop.response_model == "claude-opus-4-8"
    end

    test "an API error has a bounded error_type, status_code and request_id", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        json_resp(conn, 429, %{
          "type" => "error",
          "error" => %{"type" => "rate_limit_error", "message" => "slow down"}
        })
      end)

      assert {:error, %Claudio.APIError{}} = Claudio.Messages.create(client, span_request())

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements, stop}
      assert stop.status == :error
      assert stop.error_type == :rate_limit_error
      assert stop.status_code == 429
      assert stop.request_id == "req_test_1"
      assert is_binary(stop.error)
      refute Map.has_key?(measurements, :input_tokens)
    end

    test "a transport error has its reason as error_type and a nil status_code", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)
      Bypass.down(bypass)

      assert {:error, %Req.TransportError{}} = Claudio.Messages.create(client, span_request())

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.error_type == :econnrefused
      assert Map.has_key?(stop, :status_code)
      assert stop.status_code == nil
    end

    test "a raise inside the call emits :exception and reaches the caller", %{client: client} do
      attach(@create)
      payload = %{"model" => "m", "max_tokens" => 8, "messages" => [self()]}

      assert_raise Protocol.UndefinedError, fn -> Claudio.Messages.create(client, payload) end
      assert_receive {:telemetry, [:claudio, :messages, :create, :exception], _, meta}
      assert meta.model == "m"
      assert meta.kind == :error
    end

    test "streaming stop fires at headers and the response carries the span link", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("request-id", "req_stream_1")
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event: ping\ndata: {}\n\n")
      end)

      assert {:ok, %Req.Response{} = resp} =
               Claudio.Messages.create(client, Request.enable_streaming(span_request()))

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.stream == true
      assert stop.status == :ok
      assert stop.request_id == "req_stream_1"
      refute Map.has_key?(stop, :input_tokens)

      assert resp.private.claudio == %{
               span_context: stop.telemetry_span_context,
               model: "claude-span-model",
               request_id: "req_stream_1"
             }
    end

    test "legacy create_message/2 emits the create span", %{client: client, bypass: bypass} do
      attach(@create)
      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, message_body()))

      assert {:ok, %{"id" => "msg_span_1"}} =
               Claudio.Messages.create_message(client, %{
                 "model" => "claude-span-model",
                 "max_tokens" => 8,
                 "messages" => [%{"role" => "user", "content" => "hi"}]
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements, stop}
      assert stop.stream == false
      assert stop.response_id == "msg_span_1"
      assert stop.stop_reason == :end_turn
      assert measurements.input_tokens == 11
    end

    test "legacy create_message/2 with a non-object 200 body still returns it", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.resp(200, "plain text")
      end)

      assert {:ok, "plain text"} =
               Claudio.Messages.create_message(client, %{
                 "model" => "m",
                 "max_tokens" => 8,
                 "messages" => []
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.status == :ok
      refute Map.has_key?(stop, :response_id)
    end

    test "legacy streaming create_message/2 emits the create span", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, %Req.Response{}} =
               Claudio.Messages.create_message(client, %{
                 "model" => "m",
                 "max_tokens" => 8,
                 "stream" => true,
                 "messages" => []
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _,
                      %{stream: true, status: :ok}}
    end

    test "atom-keyed payload maps report model and request params", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)
      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, message_body()))

      assert {:ok, _} =
               Claudio.Messages.create(client, %{
                 model: "claude-atom",
                 max_tokens: 9,
                 messages: [%{role: "user", content: "hi"}]
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :start], _, start}
      assert start.model == "claude-atom"
      assert start.max_tokens == 9
    end

    test "legacy 200 with a non-list content still returns the body and emits :stop", %{
      client: client,
      bypass: bypass
    } do
      attach(@create)

      Bypass.expect_once(
        bypass,
        "POST",
        "/messages",
        &json_resp(&1, 200, %{"content" => "not a list"})
      )

      assert {:ok, %{"content" => "not a list"}} =
               Claudio.Messages.create_message(client, %{
                 "model" => "m",
                 "max_tokens" => 8,
                 "messages" => []
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements,
                      %{status: :ok}}

      refute Map.has_key?(measurements, :input_tokens)
    end

    test "a 200 without usage emits no token measurements", %{client: client, bypass: bypass} do
      attach(@create)
      body = Map.delete(message_body(), "usage")
      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, body))

      assert {:ok, _} = Claudio.Messages.create(client, span_request())

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements,
                      %{status: :ok}}

      refute Map.has_key?(measurements, :input_tokens)
      refute Map.has_key?(measurements, :output_tokens)
    end

    test "a streaming non-200 is an error stop", %{client: client, bypass: bypass} do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        json_resp(conn, 429, %{
          "type" => "error",
          "error" => %{"type" => "rate_limit_error", "message" => "slow"}
        })
      end)

      assert {:error, %Claudio.APIError{}} =
               Claudio.Messages.create(client, Request.enable_streaming(span_request()))

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.status == :error
      assert stop.error_type == :rate_limit_error
      assert stop.status_code == 429
      assert stop.request_id == "req_test_1"
    end
  end

  describe "count_tokens span" do
    @count [
      [:claudio, :messages, :count_tokens, :start],
      [:claudio, :messages, :count_tokens, :stop]
    ]

    test "success reports input_tokens as measurement and metadata", %{
      client: client,
      bypass: bypass
    } do
      attach(@count)

      Bypass.expect_once(
        bypass,
        "POST",
        "/messages/count_tokens",
        &json_resp(&1, 200, %{"input_tokens" => 42})
      )

      assert {:ok, %{"input_tokens" => 42}} =
               Claudio.Messages.count_tokens(client, %{
                 "model" => "claude-count",
                 "messages" => []
               })

      assert_receive {:telemetry, [:claudio, :messages, :count_tokens, :start], _, start}
      assert start.model == "claude-count"
      assert start.server_address == "localhost"
      refute Map.has_key?(start, :stream)

      assert_receive {:telemetry, [:claudio, :messages, :count_tokens, :stop], measurements, stop}
      assert stop.status == :ok
      assert stop.input_tokens == 42
      assert measurements.input_tokens == 42
      assert stop.request_id == "req_test_1"
    end

    test "an API error carries error_type and status_code", %{client: client, bypass: bypass} do
      attach(@count)

      Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
        json_resp(conn, 400, %{
          "type" => "error",
          "error" => %{"type" => "invalid_request_error", "message" => "bad"}
        })
      end)

      assert {:error, %Claudio.APIError{}} =
               Claudio.Messages.count_tokens(client, %{"model" => "m", "messages" => []})

      assert_receive {:telemetry, [:claudio, :messages, :count_tokens, :stop], _, stop}
      assert stop.status == :error
      assert stop.error_type == :invalid_request_error
      assert stop.status_code == 400
    end
  end
end
