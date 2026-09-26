Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ThinkingIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 120_000

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "adaptive thinking with display: :omitted and effort :high", %{client: client} do
    request =
      Request.new("claude-opus-5-5")
      |> Request.add_message(
        :user,
        "A train leaves at 09:47 and the trip takes 3 h 38 min with a 17 min delay. " <>
          "What time does it arrive? Answer with the time only."
      )
      |> Request.set_max_tokens(4096)
      |> Request.enable_adaptive_thinking(display: :omitted)
      |> Request.set_effort(:high)

    assert {:ok, %Response{} = response} = Claudio.Messages.create(client, request)

    thinking = Enum.filter(response.content, &(&1.type == :thinking))
    assert thinking != [], "expected at least one thinking block at effort :high"

    for block <- thinking do
      assert block.thinking == ""
      assert is_binary(block.signature) and block.signature != ""
    end

    assert Response.get_thinking(response) == []
    assert %{} = details = response.usage.output_tokens_details
    assert is_integer(details["thinking_tokens"] || details[:thinking_tokens])
  end
end
