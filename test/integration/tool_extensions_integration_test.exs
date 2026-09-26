Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ToolExtensionsIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.{Agent, Tools}
  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 300_000

  @model "claude-opus-5-5"

  @weather %{
    "name" => "get_weather",
    "description" => "Get current temperature in C for a city",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }
  }

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "computer toolset: member call → result with toolset_name → reply", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_computer_toolset()
      |> Request.add_message(:user, "Take a screenshot of the screen. Just the screenshot.")
      |> Request.set_max_tokens(512)

    assert {:ok, %Response{stop_reason: :tool_use} = response} = Messages.create(client, request)
    assert [%{toolset_name: "computer"} | _] = tool_uses = Tools.extract_tool_uses(response)

    results =
      Enum.map(tool_uses, fn tu ->
        Tools.create_tool_result(tu.id, "The screen shows an empty desktop.", false,
          toolset_name: tu.toolset_name
        )
      end)

    next =
      request
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, results)

    assert {:ok, %Response{}} = Messages.create(client, next)
  end

  test "tool search finds a deferred tool; the replay is accepted", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_tool_search_tool(:bm25)
      |> Request.add_tool(@weather, defer_loading: true)
      |> Request.add_message(:user, "What's the weather in Paris right now? Use your tools.")
      |> Request.set_max_tokens(1024)

    assert {:ok, %Response{} = response} = Messages.create(client, request)

    assert [%{type: :tool_search_tool_result} | _] =
             Response.get_server_tool_results(response, :tool_search_tool_result)

    # If the model answered without calling the found tool, there is nothing to replay.
    assert [_ | _] = tool_uses = Tools.extract_tool_uses(response)
    results = for tu <- tool_uses, do: Tools.create_tool_result(tu.id, "18C, cloudy")

    next =
      request
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, results)

    assert {:ok, %Response{}} = Messages.create(client, next)
  end

  test "programmatic tool calling continues with the container", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_code_execution_tool()
      |> Request.add_tool(@weather, allowed_callers: [:code_execution])
      |> Request.add_message(
        :user,
        "Write Python code that calls get_weather for Paris and London and prints the warmer city. " <>
          "Use code execution to call the tool."
      )
      |> Request.set_max_tokens(2048)

    assert {:ok, %Response{stop_reason: :tool_use, container: %{"id" => id}} = response} =
             Messages.create(client, request)

    assert [%{caller: %{"type" => "code_execution_20260120"}} | _] =
             tool_uses = Tools.extract_tool_uses(response)

    next =
      request
      |> Request.set_container(id)
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(
        :user,
        for(tu <- tool_uses, do: Tools.create_tool_result(tu.id, "15"))
      )

    assert {:ok, %Response{}} = Messages.create(client, next)
  end

  @advisor_prompt "Before answering, consult the advisor once about whether 1 is a prime " <>
                    "number. Then answer in one sentence."

  test "advisor blocks replay without the tool; add_message/3 declares the beta", %{
    client: client
  } do
    request =
      Request.new("claude-sonnet-5")
      |> Request.add_advisor_tool(@model, max_uses: 1)
      |> Request.add_message(:user, @advisor_prompt)
      |> Request.set_max_tokens(1024)

    assert {:ok, %Response{} = response} = Messages.create(client, request)
    assert [_ | _] = Response.get_server_tool_results(response, :advisor_tool_result)

    # Same first user turn: the reply's thinking block is bound to its prefix. Dropping the
    # advisor tool changes `tools` (also part of the prefix) — accepted on the probe account
    # (T4c, prefix check not enforced there); on an enforced account this replay may need
    # S15's `set_thinking_block_binding(:drop_block)`. Report such a 400 to Q.
    replay =
      Request.new("claude-sonnet-5")
      |> Request.add_message(:user, @advisor_prompt)
      |> Request.add_message(:assistant, Response.to_assistant_content(response))
      |> Request.add_message(:user, "Thanks. And 2?")
      |> Request.set_max_tokens(256)

    assert "advisor-tool-2026-03-01" in Request.required_betas(replay)
    assert {:ok, %Response{}} = Messages.create(client, replay)
  end

  test "Agent.run/4: computer toolset handler", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_computer_toolset()
      |> Request.add_message(:user, "Take one screenshot, then reply with the word done.")
      |> Request.set_max_tokens(512)

    handlers = %{
      "computer" => fn _member, _input -> {:ok, "The screen shows an empty desktop."} end
    }

    assert {:ok, %Response{}, _messages} = Agent.run(client, request, handlers, max_turns: 4)
  end

  test "Agent.run/4: programmatic calls carry the container", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_code_execution_tool()
      |> Request.add_tool(@weather, allowed_callers: [:code_execution])
      |> Request.add_message(
        :user,
        "Use code execution to call get_weather for Paris and London, then tell me which is warmer."
      )
      |> Request.set_max_tokens(2048)

    handlers = %{
      "get_weather" => fn %{"city" => city} ->
        {:ok, if(city == "Paris", do: "18", else: "15")}
      end
    }

    assert {:ok, %Response{} = final, _messages} =
             Agent.run(client, request, handlers, max_turns: 6)

    assert Response.get_text(final) =~ "Paris"
  end
end
