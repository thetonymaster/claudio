Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.SkillsIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  @moduletag :integration
  @moduletag timeout: 120_000

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "list works without the skills beta header", %{client: client} do
    assert {:ok, %{"data" => skills} = body} = Claudio.Skills.list(client, limit: 1)
    assert is_list(skills)
    # has_more only appears when skills-2025-10-02 is sent (probe, 2026-09-25)
    refute Map.has_key?(body, "has_more")
  end
end
