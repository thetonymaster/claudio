Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ContextManagementIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.APIError
  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 180_000

  @model "claude-opus-5-5"

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "edit builders: clear_thinking lands first and both betas are accepted", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_message(:user, "Say hi.")
      |> Request.set_max_tokens(256)
      |> Request.enable_adaptive_thinking()
      |> Request.add_clear_tool_uses(keep: 3)
      |> Request.add_compaction(trigger: 50_000)
      |> Request.add_clear_thinking(keep: :all)

    # The API rejects clear_thinking anywhere but first (spec F4); a 200 proves the order.
    assert {:ok, %Response{} = response} = Messages.create(client, request)
    assert response.context_management == %{"applied_edits" => []}
  end

  test "on-demand compaction round trip", %{client: client} do
    # History ending in an assistant turn is the exact shape probe P1 sent (→ 200).
    history =
      Request.new(@model)
      |> Request.add_message(:user, "My name is Q. Remember the file lib/claudio/messages.ex.")
      |> Request.add_message(:assistant, "Noted: lib/claudio/messages.ex.")
      |> Request.set_max_tokens(1024)

    assert {:ok, %Response{stop_reason: :compaction} = summary} =
             Messages.create(client, Request.request_compaction(history))

    assert %{raw: %{"signature" => signature}} = Response.compaction_block(summary)
    assert is_binary(signature)

    next =
      history
      |> Request.request_compaction()
      |> Request.apply_compaction(summary)
      |> Request.add_message(:user, "What file did I mention? One line.")
      |> Request.set_max_tokens(64)

    assert next.compaction == nil
    assert {:ok, %Response{stop_reason: stop}} = Messages.create(client, next)
    assert stop in [:end_turn, :max_tokens]
  end

  defp threshold_summary do
    Response.from_map(%{
      "model" => @model,
      "stop_reason" => "compaction",
      "content" => [%{"type" => "compaction", "content" => "The user is Q."}]
    })
  end

  test "threshold replay with the compact edit is accepted", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_compaction(trigger: 50_000)
      |> Request.apply_compaction(threshold_summary())
      |> Request.add_message(:user, "Say ok.")
      |> Request.set_max_tokens(16)

    assert {:ok, %Response{}} = Messages.create(client, request)
  end

  test "control: threshold replay without the compact edit is rejected", %{client: client} do
    request =
      Request.new(@model)
      |> Request.apply_compaction(threshold_summary())
      |> Request.add_message(:user, "Say ok.")
      |> Request.set_max_tokens(16)

    # add_message/3 declared compact-2026-01-12, so the error is about the edit (spec F11).
    assert "compact-2026-01-12" in Request.required_betas(request)

    assert {:error, %APIError{status_code: 400, message: message}} =
             Messages.create(client, request)

    assert message =~ "compact_20260112"
  end
end
