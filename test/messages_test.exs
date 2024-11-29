defmodule Claudio.MessagesTest do
  use ExUnit.Case, async: true

  import Mox
  import Tesla.Test

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    client =
      Claudio.Client.new(%{
        token:
          "fake-token",
        version: "2023-06-01",
        beta: ["token-counting-2024-11-01"]
      })

    {:ok, %{client: client}}
  end

  test "messages success", %{client: client} do
    expect_tesla_call(
      times: 1,
      returns:
        json(%Tesla.Env{status: 200}, %{
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

    assert {:ok, response} =
             Claudio.Messages.create_message(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "max_tokens" => 1024,
               "messages" => [%{"role" => "user", "content" => "Hello, world"}]
             })

    assert Map.get(response, "id") == "msg_016DmRZcBG7dB9ohnwhV3wmQ"
    assert_received_tesla_call(env, [])
    assert env.url == "https://api.anthropic.com/v1/messages"

    assert_tesla_empty_mailbox()
  end

  test "message fail", %{client: client} do
    expect_tesla_call(
      times: 1,
      returns:
        json(%Tesla.Env{status: 401}, %{
          "error" => %{
            "message" => "messages: Input should be a valid list",
            "type" => "invalid_request_error"
          },
          "type" => "error"
        })
    )

    assert {:error, _} =
             Claudio.Messages.create_message(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "max_tokens" => 1024,
               "messages" => %{"role" => "user", "content" => "Hello, world"}
             })

    assert_received_tesla_call(env, [])
    assert_tesla_empty_mailbox()
  end

  test "count tokens", %{client: client} do
    expect_tesla_call(
      times: 1,
      returns: json(%Tesla.Env{status: 200}, %{"input_tokens" => 10})
    )

    assert {:ok, _} =
             Claudio.Messages.count_tokens(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "messages" => [%{"role" => "user", "content" => "Hello, world"}]
             })

    assert_received_tesla_call(env, [])
    assert env.url == "https://api.anthropic.com/v1/messages/count_tokens"

    assert_tesla_empty_mailbox()
  end

  test "count tokens fail", %{client: client} do
    expect_tesla_call(
      times: 1,
      returns:
        json(%Tesla.Env{status: 401}, %{
          "error" => %{
            "message" => "messages.0.max-tokens: Extra inputs are not permitted",
            "type" => "invalid_request_error"
          },
          "type" => "error"
        })
    )

    assert {:error, _} =
             Claudio.Messages.count_tokens(client, %{
               "model" => "claude-3-5-sonnet-20241022",
               "messages" => [
                 %{"role" => "user", "content" => "Hello, world", "max-tokens": 1024}
               ]
             })

    assert_received_tesla_call(env, [])
    assert_tesla_empty_mailbox()
  end
end
