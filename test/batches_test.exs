defmodule Claudio.BatchesTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01", beta: ["token-counting-2024-11-01"]},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  test "create/2 merges betas from a %Request{} param and serializes it",
       %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages/batches", fn conn ->
      [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      assert beta_header =~ "context-management-2025-06-27"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      [item] = decoded["requests"]

      assert item["params"]["context_management"] ==
               %{"edits" => [%{"type" => "clear_tool_uses_20250919"}]}

      refute Map.has_key?(item["params"], "betas")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "batch_1",
          "type" => "message_batch",
          "processing_status" => "in_progress"
        })
      )
    end)

    req =
      Request.new("claude-opus-4-8")
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(16)
      |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

    requests = [%{custom_id: "r1", params: req}]

    assert {:ok, %{"id" => "batch_1"}} = Claudio.Batches.create(client, requests)
  end

  test "create/2 leaves a raw-map batch unchanged", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/messages/batches", fn conn ->
      [beta_header] = Plug.Conn.get_req_header(conn, "anthropic-beta")
      assert beta_header == "token-counting-2024-11-01"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "batch_2",
          "type" => "message_batch",
          "processing_status" => "in_progress"
        })
      )
    end)

    requests = [
      %{
        "custom_id" => "r1",
        "params" => %{
          "model" => "claude-3-5-sonnet-20241022",
          "max_tokens" => 16,
          "messages" => [%{"role" => "user", "content" => "hi"}]
        }
      }
    ]

    assert {:ok, %{"id" => "batch_2"}} = Claudio.Batches.create(client, requests)
  end
end
