Code.require_file("telemetry_helper.exs", __DIR__)

defmodule Claudio.TelemetryTest do
  use ExUnit.Case, async: true

  alias Claudio.Telemetry

  describe "usage/1" do
    test "maps atom-keyed usage, dropping nils, with thinking tokens" do
      usage = %{
        input_tokens: 10,
        output_tokens: 20,
        cache_creation_input_tokens: nil,
        cache_read_input_tokens: 4,
        output_tokens_details: %{thinking_tokens: 7}
      }

      assert Telemetry.usage(usage) == %{
               input_tokens: 10,
               output_tokens: 20,
               cache_read_input_tokens: 4,
               thinking_tokens: 7
             }
    end

    test "maps string-keyed usage" do
      usage = %{
        "input_tokens" => 1,
        "output_tokens" => 2,
        "output_tokens_details" => %{"thinking_tokens" => 3}
      }

      assert Telemetry.usage(usage) == %{input_tokens: 1, output_tokens: 2, thinking_tokens: 3}
    end

    test "nil or non-map usage is empty" do
      assert Telemetry.usage(nil) == %{}
      assert Telemetry.usage("x") == %{}
    end
  end

  describe "error_type/1" do
    test "APIError → its type" do
      assert Telemetry.error_type(%Claudio.APIError{type: :rate_limit_error}) == :rate_limit_error
      assert Telemetry.error_type(%Claudio.APIError{type: "new_error"}) == "new_error"
    end

    test "transport errors → their atom reason" do
      assert Telemetry.error_type(%Req.TransportError{reason: :econnrefused}) == :econnrefused
      assert Telemetry.error_type(%Req.TransportError{reason: :timeout}) == :timeout
    end

    test "other exceptions → their module; anything else → :unknown" do
      assert Telemetry.error_type(%RuntimeError{message: "x"}) == RuntimeError
      assert Telemetry.error_type({:weird, "tuple"}) == :unknown
    end
  end

  describe "request_metadata/1" do
    test "string-keyed payload, effort from output_config" do
      payload = %{
        "model" => "m",
        "max_tokens" => 8,
        "temperature" => 0,
        "output_config" => %{"effort" => "high"}
      }

      assert Telemetry.request_metadata(payload) == %{
               max_tokens: 8,
               temperature: 0,
               effort: "high"
             }
    end

    test "atom-keyed payload" do
      assert Telemetry.request_metadata(%{model: "m", max_tokens: 8, top_k: 5}) ==
               %{max_tokens: 8, top_k: 5}
    end
  end

  test "server_address/1 is the base_url host" do
    client =
      Claudio.Client.new(%{token: "t", version: "2023-06-01"}, "http://api.example.test:4000/v1/")

    assert Telemetry.server_address(client) == "api.example.test"
  end

  test "request_id/1 reads the request-id header" do
    assert Telemetry.request_id(Req.Response.new(headers: [{"request-id", "req_1"}])) == "req_1"
    assert Telemetry.request_id(Req.Response.new()) == nil
  end
end
