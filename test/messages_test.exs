defmodule Claudio.MessagesTest do
  use ExUnit.Case, async: true

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
end
