defmodule Claudio.BatchesTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Claudio.Messages.Response

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

  test "create/2 never forwards stream: true on a batch item (items are non-streaming)", %{
    client: client,
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "POST", "/messages/batches", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [item] = Jason.decode!(body)["requests"]
      refute Map.has_key?(item["params"], "stream")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => "b", "processing_status" => "in_progress"}))
    end)

    request =
      Request.new("m")
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(8)
      |> Request.enable_streaming()

    assert {:ok, _} = Claudio.Batches.create(client, [%{custom_id: "a", params: request}])
  end

  test "wait_for_completion/3 rejects unknown options" do
    client = Claudio.Client.new(%{token: "t"})

    assert_raise ArgumentError,
                 ~r/Batches.wait_for_completion\/3: unknown option :poll_intervall/,
                 fn ->
                   Claudio.Batches.wait_for_completion(client, "b", poll_intervall: 5)
                 end
  end

  test "list/2 rejects unknown options" do
    client = Claudio.Client.new(%{token: "t"})

    assert_raise ArgumentError, ~r/Batches.list\/2: unknown option :after/, fn ->
      Claudio.Batches.list(client, after: "x")
    end
  end

  describe "get_results/2 (pre-release audit)" do
    defp serve_results(bypass, content_type, body) do
      Bypass.expect_once(bypass, "GET", "/messages/batches/b1/results", fn conn ->
        conn |> Plug.Conn.put_resp_content_type(content_type) |> Plug.Conn.resp(200, body)
      end)
    end

    @line1 ~s({"custom_id":"a","result":{"type":"succeeded","message":{"id":"m","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}}})
    @line2 ~s({"custom_id":"b","result":{"type":"errored","error":{"type":"invalid_request_error"}}})

    test "JSONL lines decode with string keys, like Messages.create", %{
      client: client,
      bypass: bypass
    } do
      serve_results(bypass, "application/binary", @line1 <> "\n" <> @line2 <> "\n")

      assert {:ok, [first, second]} = Claudio.Batches.get_results(client, "b1")
      assert first["custom_id"] == "a"
      assert second["result"]["type"] == "errored"

      response = Response.from_map(first["result"]["message"])
      assert Response.get_text(response) == "hi"
    end

    test "a malformed line is an error, not silently dropped", %{client: client, bypass: bypass} do
      serve_results(bypass, "application/binary", @line1 <> "\n{not json\n")

      assert {:error, {:invalid_result_line, 2, "{not json"}} =
               Claudio.Batches.get_results(client, "b1")
    end

    test "a single result decoded by Req as JSON is still returned as a list", %{
      client: client,
      bypass: bypass
    } do
      serve_results(bypass, "application/json", @line1)

      assert {:ok, [%{"custom_id" => "a"}]} = Claudio.Batches.get_results(client, "b1")
    end
  end
end
