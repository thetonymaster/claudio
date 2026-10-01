Code.require_file("telemetry_helper.exs", __DIR__)

defmodule Claudio.TelemetryTest do
  use ExUnit.Case, async: true

  alias Claudio.Telemetry
  import Claudio.TelemetryTestSupport, only: [attach: 1]

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

  describe "[:claudio, :http, :request] events" do
    @http [[:claudio, :http, :request, :start], [:claudio, :http, :request, :stop]]

    setup do
      {:ok, bypass: Bypass.open()}
    end

    defp http_client(bypass, extra \\ %{}) do
      Claudio.Client.new(
        Map.merge(%{token: "t", version: "2023-06-01"}, extra),
        "http://localhost:#{bypass.port}/"
      )
    end

    # The next n telemetry messages, in arrival order.
    defp collect(n) do
      for _ <- 1..n do
        assert_receive {:telemetry, event, measurements, metadata}
        {List.last(event), measurements, metadata}
      end
    end

    @tag capture_log: true
    test "one start/stop pair per attempt, each :stop before the next :start", %{bypass: bypass} do
      attach(@http)

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          503,
          ~s({"type":"error","error":{"type":"overloaded_error","message":"busy"}})
        )
      end)

      client = http_client(bypass, %{retry: [max_retries: 2, delay: 1]})

      assert {:error, %Claudio.APIError{status_code: 503}} =
               Claudio.Messages.create(client, %{
                 "model" => "m",
                 "max_tokens" => 8,
                 "messages" => []
               })

      events = collect(6)

      assert Enum.map(events, fn {kind, _, meta} -> {kind, meta.attempt} end) ==
               [start: 0, stop: 0, start: 1, stop: 1, start: 2, stop: 2]

      for {:stop, measurements, meta} <- events do
        assert meta.status_code == 503
        assert meta.method == :post
        assert is_integer(measurements.duration)
      end

      refute_receive {:telemetry, _, _, _}, 50
    end

    test "each call starts at attempt 0", %{bypass: bypass} do
      attach(@http)
      Bypass.expect(bypass, "GET", "/models", &Plug.Conn.resp(&1, 200, ~s({"data":[]})))
      client = http_client(bypass)

      assert {:ok, _} = Claudio.Models.list(client)
      assert {:ok, _} = Claudio.Models.list(client)

      assert [
               {:start, _, %{attempt: 0}},
               {:stop, _, _},
               {:start, _, %{attempt: 0}},
               {:stop, _, _}
             ] =
               collect(4)
    end

    test "url drops the query string; non-Messages endpoints are covered", %{bypass: bypass} do
      attach(@http)

      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("request-id", "req_models")
        |> Plug.Conn.resp(200, ~s({"data":[]}))
      end)

      assert {:ok, _} = Claudio.Models.list(http_client(bypass), limit: 5)

      assert [{:start, _, start}, {:stop, _, stop}] = collect(2)
      assert start.method == :get
      assert start.url == "http://localhost:#{bypass.port}/models"
      assert is_reference(start.telemetry_span_context)
      assert stop.telemetry_span_context == start.telemetry_span_context
      assert stop.status_code == 200
      assert stop.request_id == "req_models"
    end

    test "a transport error is a :stop with error_type and nil status_code", %{bypass: bypass} do
      attach(@http)
      Bypass.down(bypass)

      assert {:error, %Req.TransportError{}} =
               Claudio.Models.list(http_client(bypass, %{retry: false}))

      assert [{:start, _, _}, {:stop, _, stop}] = collect(2)
      assert stop.error_type == :econnrefused
      assert Map.has_key?(stop, :status_code)
      assert stop.status_code == nil
    end
  end
end
