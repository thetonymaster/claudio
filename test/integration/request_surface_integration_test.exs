Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.RequestSurfaceIntegrationTest do
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

  test "system messages (effort-only + clear_at), inference_geo :us, cache diagnostics", %{
    client: client
  } do
    request =
      Request.new("claude-opus-5-5")
      |> Request.add_system_message([], effort: :low)
      |> Request.add_message(:user, "Name a primary color.")
      |> Request.add_system_message("Answer in one word.", clear_at: :next_user_message)
      |> Request.set_max_tokens(256)
      |> Request.set_inference_geo(:us)
      |> Request.enable_cache_diagnostics()

    assert {:ok, %Response{} = response} = Claudio.Messages.create(client, request)
    assert response.usage.inference_geo == "us"
    assert is_binary(response.usage.service_tier)
    assert response.stop_reason in [:end_turn, :max_tokens]
  end
end
