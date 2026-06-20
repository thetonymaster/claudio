Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ModelsIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Claudio.Models

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  describe "list/2 + get/2 (live)" do
    test "lists models and retrieves one by id", %{client: client} do
      assert {:ok, %{"data" => models}} = Models.list(client, limit: 5)
      assert is_list(models)
      assert length(models) > 0

      first_id = hd(models)["id"]
      assert is_binary(first_id)

      assert {:ok, model} = Models.get(client, first_id)
      assert model["id"] == first_id
      assert model["type"] == "model"
    end

    test "a bogus model id returns a 404 APIError", %{client: client} do
      assert {:error, %Claudio.APIError{status_code: 404}} =
               Models.get(client, "claude-does-not-exist-00000000")
    end
  end
end
