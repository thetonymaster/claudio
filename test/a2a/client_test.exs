defmodule Claudio.A2A.ClientTest do
  use ExUnit.Case, async: true

  alias Claudio.A2A.{Client, Message, Part, Task}

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  describe "discover/2" do
    test "fetches and parses agent card", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/.well-known/agent-card.json", fn conn ->
        body =
          Poison.encode!(%{
            "name" => "Test Agent",
            "description" => "A test agent",
            "version" => "1.0.0",
            "defaultInputModes" => ["text/plain"],
            "defaultOutputModes" => ["text/plain"],
            "skills" => [
              %{"id" => "search", "name" => "Search", "description" => "Search", "tags" => []}
            ],
            "supportedInterfaces" => [
              %{
                "url" => "#{base_url}/a2a",
                "protocolBinding" => "jsonrpc+http",
                "protocolVersion" => "0.3"
              }
            ]
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      {:ok, card} = Client.discover(base_url)
      assert card.name == "Test Agent"
      assert card.version == "1.0.0"
      assert hd(card.skills).id == "search"
    end

    test "returns error on 404", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "GET", "/.well-known/agent-card.json", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      assert {:error, {:http_error, 404}} = Client.discover(base_url)
    end
  end

  describe "send_message/3" do
    test "sends JSON-RPC request and returns task", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        assert request["jsonrpc"] == "2.0"
        assert request["method"] == "message/send"
        assert request["params"]["message"]["role"] == "user"

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "id" => "task-abc",
              "status" => %{"state" => "TASK_STATE_WORKING"},
              "history" => [request["params"]["message"]]
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      message = Message.new(:user, [Part.text("Hello agent")])
      {:ok, task} = Client.send_message("#{base_url}/a2a", message)

      assert %Task{} = task
      assert task.id == "task-abc"
      assert task.status.state == :working
    end

    test "returns Message when agent responds directly", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "messageId" => "msg-resp-1",
              "role" => "agent",
              "parts" => [%{"text" => "Here's your answer directly."}]
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      message = Message.new(:user, [Part.text("Quick question")])
      {:ok, result} = Client.send_message("#{base_url}/a2a", message)

      assert %Message{} = result
      assert result.message_id == "msg-resp-1"
      assert result.role == :agent
      assert hd(result.parts).text == "Here's your answer directly."
    end

    test "returns JSON-RPC error", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_001, "message" => "Task not found"}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      message = Message.new(:user, [Part.text("Hello")])

      assert {:error, %{code: -32_001, message: "Task not found"}} =
               Client.send_message("#{base_url}/a2a", message)
    end
  end

  describe "get_task/3" do
    test "fetches task by ID", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        assert request["method"] == "tasks/get"
        assert request["params"]["id"] == "task-123"

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "id" => "task-123",
              "status" => %{"state" => "TASK_STATE_COMPLETED"},
              "artifacts" => [%{"artifactId" => "art-1", "parts" => [%{"text" => "Done"}]}]
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      {:ok, task} = Client.get_task("#{base_url}/a2a", "task-123")
      assert task.id == "task-123"
      assert task.status.state == :completed
      assert length(task.artifacts) == 1
    end
  end

  describe "list_tasks/2" do
    test "lists tasks with pagination", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        assert request["method"] == "tasks/list"

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "tasks" => [
                %{"id" => "t-1", "status" => %{"state" => "completed"}},
                %{"id" => "t-2", "status" => %{"state" => "working"}}
              ],
              "nextPageToken" => "token-2"
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      {:ok, result} = Client.list_tasks("#{base_url}/a2a")
      assert length(result.tasks) == 2
      assert result.next_page_token == "token-2"
    end
  end

  describe "cancel_task/3" do
    test "cancels a task", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        assert request["method"] == "tasks/cancel"
        assert request["params"]["id"] == "task-to-cancel"

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "id" => "task-to-cancel",
              "status" => %{"state" => "TASK_STATE_CANCELED"}
            }
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      {:ok, task} = Client.cancel_task("#{base_url}/a2a", "task-to-cancel")
      assert task.status.state == :canceled
    end
  end

  describe "authentication" do
    test "sends bearer token when provided", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer my-secret-token"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{"id" => "t-1", "status" => %{"state" => "working"}}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      message = Message.new(:user, [Part.text("Hi")])

      {:ok, _task} =
        Client.send_message("#{base_url}/a2a", message, auth_token: "my-secret-token")
    end
  end

  describe "transport option" do
    test "uses explicit HTTP transport", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/a2a", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Poison.decode!(body)

        response =
          Poison.encode!(%{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{"id" => "t-explicit", "status" => %{"state" => "working"}}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, response)
      end)

      message = Message.new(:user, [Part.text("Hi")])

      {:ok, task} =
        Client.send_message("#{base_url}/a2a", message, transport: Claudio.A2A.Transport.HTTP)

      assert task.id == "t-explicit"
    end

    test "gRPC transport returns not implemented" do
      message = Message.new(:user, [Part.text("Hi")])

      assert {:error, :grpc_not_implemented} =
               Client.send_message("localhost:443", message,
                 transport: Claudio.A2A.Transport.GRPC
               )
    end
  end
end
