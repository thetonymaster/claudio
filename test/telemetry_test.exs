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

    test "a non-map output_tokens_details yields no :thinking_tokens" do
      assert Telemetry.usage(%{"input_tokens" => 1, "output_tokens_details" => "x"}) ==
               %{input_tokens: 1}

      assert Telemetry.usage(%{output_tokens: 2, output_tokens_details: [1]}) ==
               %{output_tokens: 2}
    end

    test "a present atom key wins, even when invalid; the string key is only a fallback" do
      assert Telemetry.usage(%{:input_tokens => false, "input_tokens" => 5}) == %{}

      assert Telemetry.usage(%{"input_tokens" => 5}) == %{input_tokens: 5}
    end
  end

  describe "usage/1 integer-only tokens" do
    test "string, float, map and negative values are dropped" do
      usage = %{
        "input_tokens" => "3",
        "output_tokens" => 4.0,
        "cache_creation_input_tokens" => %{"x" => 1},
        "cache_read_input_tokens" => -1,
        "output_tokens_details" => %{"thinking_tokens" => "7"}
      }

      assert Telemetry.usage(usage) == %{}

      assert Telemetry.usage(%{output_tokens: 2, output_tokens_details: %{thinking_tokens: 1.5}}) ==
               %{output_tokens: 2}
    end
  end

  describe "error_type/1 bounds server-supplied strings" do
    test "a snake_case string passes; free text becomes :unknown" do
      assert Telemetry.error_type(%Claudio.APIError{type: "new_error"}) == "new_error"
      assert Telemetry.error_type(%Claudio.APIError{type: "proxy says: USERCONTENT"}) == :unknown
      assert Telemetry.error_type(%Claudio.APIError{type: String.duplicate("a", 65)}) == :unknown
      assert Telemetry.error_type(%Claudio.APIError{type: ""}) == :unknown
    end

    test "bounded_type/1 is shared with the stream error path" do
      assert Telemetry.bounded_type("overloaded_error") == "overloaded_error"
      assert Telemetry.bounded_type("overloaded: detail") == nil
    end
  end

  test "server_address/1 is nil for a client that is not a Req.Request" do
    assert Telemetry.server_address(base_url: "https://api.anthropic.com/v1/") == nil
  end

  describe "error_type/1" do
    test "APIError → its type" do
      assert Telemetry.error_type(%Claudio.APIError{type: :rate_limit_error}) == :rate_limit_error
      assert Telemetry.error_type(%Claudio.APIError{type: "new_error"}) == "new_error"
    end

    test "APIError without a type → :unknown" do
      assert Telemetry.error_type(%Claudio.APIError{type: nil}) == :unknown
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

  test "server_port/1 is the explicit port or the scheme default" do
    mk = &Claudio.Client.new(%{token: "t", version: "v"}, &1)
    assert Telemetry.server_port(mk.("http://api.example.test:4000/v1/")) == 4000
    assert Telemetry.server_port(mk.("https://api.example.test/v1/")) == 443
    assert Telemetry.server_port(mk.("http://api.example.test/v1/")) == 80
    assert Telemetry.server_port(Req.new()) == nil
    assert Telemetry.server_port(base_url: "https://x/") == nil
  end

  test "server_address/1 and server_port/1 accept a %URI{} base_url" do
    req = Req.new(base_url: URI.parse("https://api.example.test/v1/"))
    assert Telemetry.server_address(req) == "api.example.test"
    assert Telemetry.server_port(req) == 443
  end

  defmodule StaticAdapter do
    @moduledoc false
    # A custom Req adapter returning a canned response (ignores `into:`, keeps atom keys).
    def run(request), do: {request, Req.Request.get_private(request, :static_response)}
  end

  describe "custom adapters" do
    defp adapter_client(response) do
      %{token: "t", version: "2023-06-01"}
      |> Claudio.Client.new("http://localhost:1/")
      |> Req.merge(retry: false, adapter: StaticAdapter)
      |> Req.Request.put_private(:static_response, response)
    end

    test "an atom-keyed 200 body still yields create :stop token data" do
      attach([[:claudio, :messages, :create, :stop]])

      body = %{
        id: "msg_1",
        type: "message",
        role: "assistant",
        model: "m",
        content: [],
        stop_reason: "end_turn",
        usage: %{input_tokens: 3, output_tokens: 5}
      }

      client = adapter_client(Req.Response.new(status: 200, body: body))
      payload = %{"model" => "m", "max_tokens" => 8, "messages" => []}

      assert {:ok, _} = Claudio.Messages.create(client, payload)
      assert_receive {:telemetry, _, %{input_tokens: 3, output_tokens: 5}, %{input_tokens: 3}}
    end

    test "a streaming non-200 with a plain binary body is an APIError" do
      body = ~s({"type":"error","error":{"type":"overloaded_error","message":"busy"}})
      client = adapter_client(Req.Response.new(status: 529, body: body))
      payload = %{"model" => "m", "max_tokens" => 8, "messages" => [], "stream" => true}

      assert {:error, %Claudio.APIError{type: :overloaded_error}} =
               Claudio.Messages.create(client, payload)
    end
  end

  test "server_address/1 is nil without a base_url" do
    assert Telemetry.server_address(Req.new()) == nil
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
      refute Map.has_key?(stop, :error_type)
    end

    test "url drops userinfo, query and fragment", %{bypass: bypass} do
      attach(@http)
      Bypass.expect_once(bypass, "GET", "/models", &Plug.Conn.resp(&1, 200, ~s({"data":[]})))

      client =
        Claudio.Client.new(
          %{token: "t", version: "2023-06-01"},
          "http://user:pass@localhost:#{bypass.port}/"
        )

      assert {:ok, _} = Claudio.Models.list(client, limit: 5)
      assert [{:start, _, start}, {:stop, _, _}] = collect(2)
      assert start.url == "http://localhost:#{bypass.port}/models"
      refute start.url =~ "user"
      refute start.url =~ "pass"
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

    test "a body that fails to decode still yields exactly one :stop per attempt", %{
      bypass: bypass
    } do
      attach(@http)

      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{bad")
      end)

      Claudio.Models.list(http_client(bypass, %{retry: false}))

      assert [{:start, _, _}, {:stop, _, %{status_code: 200}}] = collect(2)
      refute_receive {:telemetry, _, _, _}, 50
    end
  end

  describe "no event carries the credential" do
    test "with an API key client" do
      assert_no_secret(%{})
    end

    test "with a bearer client" do
      assert_no_secret(%{auth_type: :bearer})
    end
  end

  describe "error paths" do
    test "the API error body reaches only create :stop's deprecated `error`" do
      bypass = Bypass.open()
      secret = "BODY-SECRET-#{System.unique_integer([:positive])}"

      attach([
        [:claudio, :messages, :create, :stop],
        [:claudio, :messages, :count_tokens, :stop],
        [:claudio, :http, :request, :stop]
      ])

      error_body =
        ~s({"type":"error","error":{"type":"invalid_request_error","message":"#{secret}"}})

      for path <- ["/messages", "/messages/count_tokens"] do
        Bypass.expect_once(bypass, "POST", path, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(400, error_body)
        end)
      end

      client =
        Claudio.Client.new(
          %{token: "t", version: "2023-06-01"},
          "http://localhost:#{bypass.port}/"
        )

      payload = %{
        "model" => "x",
        "max_tokens" => 8,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      }

      assert {:error, _} = Claudio.Messages.create(client, payload)
      assert {:error, _} = Claudio.Messages.count_tokens(client, payload)

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, create_stop}
      assert_receive {:telemetry, [:claudio, :messages, :count_tokens, :stop], _, count_stop}
      assert_receive {:telemetry, [:claudio, :http, :request, :stop], _, http_stop}
      assert_receive {:telemetry, [:claudio, :http, :request, :stop], _, count_http_stop}

      assert create_stop.error =~ secret
      assert create_stop.error_type == :invalid_request_error
      assert_clean(Map.delete(create_stop, :error), secret, :create)
      refute Map.has_key?(count_stop, :error)
      assert count_stop.error_type == :invalid_request_error
      assert_clean(count_stop, secret, :count_tokens)
      assert_clean(http_stop, secret, :http)
      assert_clean(count_http_stop, secret, :http)
    end
  end

  defp assert_no_secret(client_opts) do
    bypass = Bypass.open()
    secret = "sk-test-SECRET-#{System.unique_integer([:positive])}"

    events =
      for prefix <- [
            [:claudio, :messages, :create],
            [:claudio, :messages, :count_tokens],
            [:claudio, :http, :request],
            [:claudio, :messages, :stream]
          ],
          suffix <- [:start, :stop, :exception],
          do: prefix ++ [suffix]

    attach(events)

    Bypass.expect(bypass, "POST", "/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if Jason.decode!(body)["stream"] == true do
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, sse_body())
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"id":"m","type":"message","role":"assistant","model":"x","content":[],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}})
        )
      end
    end)

    Bypass.expect(
      bypass,
      "POST",
      "/messages/count_tokens",
      &Plug.Conn.resp(&1, 200, ~s({"input_tokens":1}))
    )

    Bypass.expect(bypass, "GET", "/models", &Plug.Conn.resp(&1, 200, ~s({"data":[]})))

    client =
      Claudio.Client.new(
        Map.merge(%{token: secret, version: "2023-06-01"}, client_opts),
        "http://localhost:#{bypass.port}/"
      )

    payload = %{
      "model" => "x",
      "max_tokens" => 8,
      "messages" => [%{"role" => "user", "content" => "hi"}]
    }

    assert {:ok, _} = Claudio.Messages.create(client, payload)
    assert {:ok, _} = Claudio.Messages.count_tokens(client, payload)
    assert {:ok, _} = Claudio.Models.list(client)

    assert {:ok, %Req.Response{} = resp} =
             Claudio.Messages.create(client, Map.put(payload, "stream", true))

    resp |> Claudio.Messages.Stream.parse_events() |> Stream.run()

    received =
      Stream.repeatedly(fn ->
        receive do
          msg -> msg
        after
          50 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    names = for {:telemetry, event, _, _} <- received, do: event
    assert length(names) >= 14
    assert [:claudio, :messages, :stream, :stop] in names

    for {:telemetry, event, measurements, metadata} <- received do
      refute inspect({measurements, metadata}, limit: :infinity, printable_limit: :infinity) =~
               secret,
             "#{inspect(event)} leaked the credential"

      # Req's inspect redacts `authorization`, so also walk the values themselves.
      for value <- [measurements, metadata] do
        assert_clean(value, secret, event)
      end
    end
  end

  defp sse_body do
    Enum.map_join(
      [
        {"message_start",
         ~s({"type":"message_start","message":{"id":"m","model":"x","content":[],"usage":{"input_tokens":1,"output_tokens":1}}})},
        {"message_delta",
         ~s({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}})},
        {"message_stop", ~s({"type":"message_stop"})}
      ],
      fn {event, data} -> "event: #{event}\ndata: #{data}\n\n" end
    )
  end

  defp assert_clean(%struct{}, _secret, event) when struct in [Req.Request, Req.Response],
    do: flunk("#{inspect(event)} carries a #{inspect(struct)}")

  defp assert_clean(%_{} = struct, secret, event),
    do: assert_clean(Map.from_struct(struct), secret, event)

  defp assert_clean(%{} = map, secret, event) do
    for {key, value} <- map do
      assert_clean(key, secret, event)
      assert_clean(value, secret, event)
    end
  end

  defp assert_clean(list, secret, event) when is_list(list),
    do: Enum.each(list, &assert_clean(&1, secret, event))

  defp assert_clean(tuple, secret, event) when is_tuple(tuple),
    do: assert_clean(Tuple.to_list(tuple), secret, event)

  defp assert_clean(binary, secret, event) when is_binary(binary),
    do: refute(binary =~ secret, "#{inspect(event)} leaked the credential")

  defp assert_clean(_other, _secret, _event), do: :ok
end
