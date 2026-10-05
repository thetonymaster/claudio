Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ReleaseAuditIntegrationTest do
  # Live checks for the 0.7.0 pre-release audit fixes (each was a 400 before the fix).
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 120_000

  @model "claude-opus-5-5"

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "a paired MCP call replays through to_assistant_content/1 (no server_name)", %{
    client: client
  } do
    content = [
      %{
        "type" => "mcp_tool_use",
        "id" => "mcptoolu_01",
        "name" => "x",
        "server_name" => "s",
        "input" => %{}
      },
      %{
        "type" => "mcp_tool_result",
        "tool_use_id" => "mcptoolu_01",
        "is_error" => false,
        "content" => [%{"type" => "text", "text" => "ok"}]
      },
      %{"type" => "text", "text" => "done"}
    ]

    replay = Response.to_assistant_content(Response.from_map(%{"content" => content}))

    request =
      Request.new(@model)
      |> Request.add_message(:user, "hi")
      |> Request.add_message(:assistant, replay)
      |> Request.add_message(:user, "Say ok.")
      |> Request.set_max_tokens(16)

    # No add_beta: add_message/3 declares mcp-client-2025-11-20 for the replayed MCP blocks.
    assert {:ok, %Response{}} = Messages.create(client, request)
  end

  test "count_tokens accepts a request that uses sampling and runtime fields", %{client: client} do
    request =
      Request.new("claude-haiku-4-5")
      |> Request.add_message(:user, "hi")
      |> Request.set_temperature(0.5)
      |> Request.set_top_k(5)
      |> Request.set_stop_sequences(["X"])
      |> Request.set_metadata(%{"user_id" => "u1"})
      |> Request.set_service_tier("auto")

    assert {:ok, %{"input_tokens" => n}} = Messages.count_tokens(client, request)
    assert n > 0
  end

  test "response.content passed straight to add_message/3 replays (no null caller)", %{
    client: client
  } do
    tool = %{
      "name" => "get_weather",
      "description" => "Get the weather for a city",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }
    }

    request =
      Request.new(@model)
      |> Request.add_tool(tool)
      |> Request.set_tool_choice(:auto)
      |> Request.add_message(:user, "What's the weather in Paris? Use the tool.")
      |> Request.set_max_tokens(512)

    assert {:ok, %Response{stop_reason: :tool_use} = response} = Messages.create(client, request)
    [tool_use] = Response.get_tool_uses(response)

    next =
      request
      |> Request.add_message(:assistant, response.content)
      |> Request.add_message(:user, [Claudio.Tools.create_tool_result(tool_use.id, "18C")])

    assert {:ok, %Response{}} = Messages.create(client, next)
  end
end
