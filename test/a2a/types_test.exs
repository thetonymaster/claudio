defmodule Claudio.A2A.TypesTest do
  use ExUnit.Case, async: true

  alias Claudio.A2A.{Part, Message, Artifact, Task, AgentCard}

  describe "Part" do
    test "text/1 creates a text part" do
      part = Part.text("hello")
      assert part.text == "hello"
      assert part.url == nil
    end

    test "file/2 creates a file part" do
      part = Part.file("https://example.com/doc.pdf", "application/pdf")
      assert part.url == "https://example.com/doc.pdf"
      assert part.media_type == "application/pdf"
    end

    test "data/1 creates a data part" do
      part = Part.data(%{"key" => "value"})
      assert part.data == %{"key" => "value"}
    end

    test "to_map/1 omits nil fields" do
      map = Part.text("hello") |> Part.to_map()
      assert map == %{"text" => "hello"}
      refute Map.has_key?(map, "url")
    end

    test "from_map/1 parses camelCase keys" do
      part = Part.from_map(%{"text" => "hi", "mediaType" => "text/plain"})
      assert part.text == "hi"
      assert part.media_type == "text/plain"
    end

    test "round-trip to_map -> from_map" do
      original = %Part{text: "hello", media_type: "text/plain", filename: "test.txt"}
      result = original |> Part.to_map() |> Part.from_map()
      assert result.text == original.text
      assert result.media_type == original.media_type
      assert result.filename == original.filename
    end
  end

  describe "Message" do
    test "new/2 creates a message with auto-generated ID" do
      msg = Message.new(:user, [Part.text("Hello")])
      assert msg.role == :user
      assert length(msg.parts) == 1
      assert String.starts_with?(msg.message_id, "msg-")
    end

    test "set_task_id/2 chains" do
      msg =
        Message.new(:user, [Part.text("Hi")])
        |> Message.set_task_id("task-123")

      assert msg.task_id == "task-123"
    end

    test "to_map/1 outputs camelCase" do
      map =
        Message.new(:agent, [Part.text("Hi")])
        |> Message.set_task_id("t-1")
        |> Message.to_map()

      assert map["role"] == "agent"
      assert map["taskId"] == "t-1"
      assert is_binary(map["messageId"])
      assert [%{"text" => "Hi"}] = map["parts"]
    end

    test "from_map/1 parses camelCase" do
      msg =
        Message.from_map(%{
          "messageId" => "msg-abc",
          "role" => "user",
          "parts" => [%{"text" => "Hello"}],
          "contextId" => "ctx-1"
        })

      assert msg.message_id == "msg-abc"
      assert msg.role == :user
      assert msg.context_id == "ctx-1"
      assert hd(msg.parts).text == "Hello"
    end
  end

  describe "Artifact" do
    test "from_map/1 parses camelCase" do
      artifact =
        Artifact.from_map(%{
          "artifactId" => "art-1",
          "name" => "report",
          "parts" => [%{"text" => "Report content"}]
        })

      assert artifact.artifact_id == "art-1"
      assert artifact.name == "report"
      assert hd(artifact.parts).text == "Report content"
    end

    test "to_map/1 outputs camelCase" do
      map =
        %Artifact{
          artifact_id: "art-1",
          name: "report",
          parts: [Part.text("content")]
        }
        |> Artifact.to_map()

      assert map["artifactId"] == "art-1"
      assert map["name"] == "report"
    end
  end

  describe "Task" do
    test "from_map/1 parses full task" do
      task =
        Task.from_map(%{
          "id" => "task-1",
          "contextId" => "ctx-1",
          "status" => %{
            "state" => "TASK_STATE_WORKING",
            "timestamp" => "2026-04-02T10:00:00Z"
          },
          "artifacts" => [
            %{"artifactId" => "art-1", "parts" => [%{"text" => "result"}]}
          ],
          "history" => [
            %{"messageId" => "msg-1", "role" => "user", "parts" => [%{"text" => "do it"}]}
          ]
        })

      assert task.id == "task-1"
      assert task.context_id == "ctx-1"
      assert task.status.state == :working
      assert task.status.timestamp == "2026-04-02T10:00:00Z"
      assert length(task.artifacts) == 1
      assert length(task.history) == 1
    end

    test "from_map/1 handles lowercase state values" do
      task =
        Task.from_map(%{
          "id" => "t-2",
          "status" => %{"state" => "completed"}
        })

      assert task.status.state == :completed
    end

    test "terminal?/1 detects terminal states" do
      completed = Task.from_map(%{"id" => "t", "status" => %{"state" => "completed"}})
      working = Task.from_map(%{"id" => "t", "status" => %{"state" => "working"}})

      assert Task.terminal?(completed)
      refute Task.terminal?(working)
    end

    test "to_map/1 serializes correctly" do
      task =
        Task.from_map(%{
          "id" => "task-1",
          "status" => %{"state" => "TASK_STATE_COMPLETED"}
        })

      map = Task.to_map(task)
      assert map["id"] == "task-1"
      assert map["status"]["state"] == "TASK_STATE_COMPLETED"
    end
  end

  describe "AgentCard" do
    test "from_map/1 parses full agent card" do
      card =
        AgentCard.from_map(%{
          "name" => "Test Agent",
          "description" => "A test agent",
          "version" => "1.0.0",
          "provider" => %{"url" => "https://example.com", "organization" => "Test Org"},
          "capabilities" => %{"streaming" => true, "pushNotifications" => false},
          "defaultInputModes" => ["text/plain"],
          "defaultOutputModes" => ["text/plain", "application/json"],
          "skills" => [
            %{
              "id" => "search",
              "name" => "Search",
              "description" => "Web search",
              "tags" => ["web"]
            }
          ],
          "supportedInterfaces" => [
            %{
              "url" => "https://agent.example.com/a2a",
              "protocolBinding" => "jsonrpc+http",
              "protocolVersion" => "0.3"
            }
          ]
        })

      assert card.name == "Test Agent"
      assert card.version == "1.0.0"
      assert card.provider.organization == "Test Org"
      assert card.capabilities.streaming == true
      assert card.capabilities.push_notifications == false
      assert length(card.skills) == 1
      assert hd(card.skills).id == "search"
      assert hd(card.supported_interfaces).protocol_binding == "jsonrpc+http"
    end

    test "builder chain produces correct card" do
      card =
        AgentCard.new("My Agent", "Does things")
        |> AgentCard.set_version("2.0.0")
        |> AgentCard.set_provider("https://me.com", "Me Inc")
        |> AgentCard.add_skill("fetch", "Fetch URLs", tags: ["http"])
        |> AgentCard.add_interface("https://a.com/a2a", "jsonrpc+http", "0.3")
        |> AgentCard.set_capabilities(streaming: true)

      assert card.name == "My Agent"
      assert card.version == "2.0.0"
      assert card.provider.organization == "Me Inc"
      assert length(card.skills) == 1
      assert card.capabilities.streaming == true
    end

    test "to_map/1 outputs camelCase" do
      map =
        AgentCard.new("Agent", "Desc")
        |> AgentCard.set_version("1.0")
        |> AgentCard.add_skill("s1", "Skill one", tags: ["t"])
        |> AgentCard.add_interface("https://a.com", "jsonrpc+http", "0.3")
        |> AgentCard.to_map()

      assert map["name"] == "Agent"
      assert map["version"] == "1.0"
      assert [%{"id" => "s1"}] = map["skills"]
      assert [%{"protocolBinding" => "jsonrpc+http"}] = map["supportedInterfaces"]
    end

    test "round-trip to_map -> from_map" do
      original =
        AgentCard.new("RT Agent", "Round trip test")
        |> AgentCard.set_version("1.0.0")
        |> AgentCard.set_provider("https://rt.com", "RT Org")
        |> AgentCard.add_skill("test", "Test skill", tags: ["test"])
        |> AgentCard.add_interface("https://rt.com/a2a", "jsonrpc+http", "0.3")
        |> AgentCard.set_capabilities(streaming: true)

      result = original |> AgentCard.to_map() |> AgentCard.from_map()

      assert result.name == original.name
      assert result.version == original.version
      assert result.provider.organization == "RT Org"
      assert hd(result.skills).id == "test"
      assert result.capabilities.streaming == true
    end
  end
end
