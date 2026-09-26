Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.FallbacksIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.APIError
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 120_000

  @model "claude-opus-5-5"
  # mcp_tool_use blocks in history need the MCP connector beta (probed 2026-09-25).
  @mcp_beta "mcp-client-2025-11-20"

  # Content as a streamed mid-output fallback leaves it (RF "Continuing the
  # conversation"). A refusal can't be triggered on demand, but the API validates a
  # caller-built fallback block in history, so the echo rules can be checked live.
  @fallback %{
    "type" => "fallback",
    "from" => %{"model" => "claude-opus-5-5"},
    "to" => %{"model" => "claude-opus-4-8"}
  }

  @unpaired [
    tool_use: %{"type" => "tool_use", "id" => "toolu_01", "name" => "x", "input" => %{}},
    server_tool_use: %{
      "type" => "server_tool_use",
      "id" => "srvtoolu_01",
      "name" => "web_search",
      "input" => %{"query" => "x"}
    },
    mcp_tool_use: %{
      "type" => "mcp_tool_use",
      "id" => "mcptoolu_01",
      "name" => "x",
      "server_name" => "s",
      "input" => %{}
    }
  ]

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  defp replay(client, assistant_content) do
    request =
      Request.new(@model)
      |> Request.add_message(:user, "hi")
      |> Request.add_message(:assistant, assistant_content)
      |> Request.add_message(:user, "Say ok.")
      |> Request.set_max_tokens(16)
      # No set_fallbacks/2: the fallback beta must come from add_message/3 (spec F15).
      |> Request.add_beta(@mcp_beta)

    Claudio.Messages.create(client, request)
  end

  defp mid_output(blocks) do
    blocks ++
      [
        %{"type" => "text", "text" => "Partial"},
        @fallback,
        %{"type" => "text", "text" => "Hello!"}
      ]
  end

  test "fallbacks: :default is accepted and usage.iterations is reported", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_message(:user, "Name a primary color.")
      |> Request.set_max_tokens(64)
      |> Request.set_fallbacks(:default)

    assert {:ok, %Response{} = response} = Claudio.Messages.create(client, request)
    assert [%{"type" => _} | _] = response.usage.iterations
    assert is_binary(Response.served_by(response))
  end

  test "to_assistant_content/1 output replays after a mid-output fallback", %{client: client} do
    response =
      Response.from_map(%{"model" => @model, "content" => mid_output(Keyword.values(@unpaired))})

    content = Response.to_assistant_content(response)

    assert Enum.map(content, & &1["type"]) == ["text", "fallback", "text"]
    assert {:ok, %Response{}} = replay(client, content)
  end

  for type <- [:tool_use, :server_tool_use, :mcp_tool_use] do
    @tag block_type: type
    test "control: replaying an unpaired #{type} before the fallback is rejected", %{
      client: client,
      block_type: block_type
    } do
      raw = mid_output([Keyword.fetch!(@unpaired, block_type)])

      assert {:error, %APIError{status_code: 400, message: message}} = replay(client, raw)
      assert message =~ "tool_result"
    end
  end
end
