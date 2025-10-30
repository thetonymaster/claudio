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

  # Streaming is tested in integration tests
  # See test/integration/streaming_integration_test.exs
end
