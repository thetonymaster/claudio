Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.BlockBindingIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.APIError
  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 180_000

  @model "claude-opus-5-5"
  @question "Think step by step: what is 17*23? Answer with the number."

  setup_all do
    case skip_if_no_api_key() do
      :ok ->
        client = create_client()

        # Same setup as thinking_integration_test.exs: effort :high so adaptive thinking
        # actually thinks, and room to finish so the reply has text after the thinking.
        request =
          Request.new(@model)
          |> Request.enable_adaptive_thinking()
          |> Request.set_effort(:high)
          |> Request.add_message(:user, @question)
          |> Request.set_max_tokens(4096)

        case Messages.create(client, request) do
          {:ok, %Response{stop_reason: :end_turn} = response} ->
            {:ok, %{client: client, first: response}}

          other ->
            raise "block-binding fixture call failed: #{inspect(other)}"
        end

      {:skip, reason} ->
        {:skip, reason}
    end
  end

  # Same assistant turn, but the user message before it was edited: the thinking block's
  # signature no longer matches its prefix.
  defp edited_history(first, behavior) do
    Request.new(@model)
    |> Request.enable_adaptive_thinking(block_binding: behavior)
    |> Request.add_message(:user, @question <> " Please.")
    |> Request.add_message(:assistant, Response.to_assistant_content(first))
    |> Request.add_message(:user, "Now add 1. Number only.")
    |> Request.set_max_tokens(256)
  end

  test "the first reply carries a signed thinking block and text", %{first: first} do
    assert Enum.any?(
             first.content,
             &match?(%{type: :thinking, signature: sig} when is_binary(sig), &1)
           )

    assert Response.get_text(first) != ""
  end

  test ":error rejects an edited prefix", %{client: client, first: first} do
    assert {:error, %APIError{status_code: 400, message: message}} =
             Messages.create(client, edited_history(first, :error))

    assert message =~ "bound to a different conversation"
  end

  test ":drop_block drops the block and reports it", %{client: client, first: first} do
    assert {:ok, %Response{input_transformations: transformations}} =
             Messages.create(client, edited_history(first, :drop_block))

    # The failing block and every later thinking block are dropped (spec F4), so there may
    # be more than one entry; each must be a prefix-mismatch drop.
    assert [_ | _] = transformations

    assert Enum.all?(
             transformations,
             &match?(%{"type" => "thinking_dropped", "reason" => "prefix_binding_mismatch"}, &1)
           )
  end
end
