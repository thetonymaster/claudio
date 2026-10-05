defmodule Claudio.ClientTest.RetryProbeAdapter do
  @moduledoc false
  # Answers `status`/`headers` first, then a 200; records each call's monotonic time.
  def run(request) do
    {times, status, headers} = Req.Request.get_private(request, :retry_probe)
    Agent.update(times, &[System.monotonic_time(:millisecond) | &1])

    if length(Agent.get(times, & &1)) == 1 do
      {request, Req.Response.new(status: status, headers: headers, body: "")}
    else
      body =
        Jason.encode!(%{
          "id" => "m",
          "type" => "message",
          "role" => "assistant",
          "model" => "x",
          "content" => [],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })

      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: body
       )}
    end
  end
end

defmodule Claudio.ClientTest do
  # Not async: these tests change global application env that every client reads.
  use ExUnit.Case, async: false

  alias Claudio.Messages.Request

  describe "timeout configuration" do
    setup do
      # Save original config
      original_config = Application.get_env(:claudio, Claudio.Client)

      on_exit(fn ->
        # Restore original config
        if original_config do
          Application.put_env(:claudio, Claudio.Client, original_config)
        else
          Application.delete_env(:claudio, Claudio.Client)
        end
      end)

      :ok
    end

    test "uses default timeouts when no config is set" do
      Application.delete_env(:claudio, Claudio.Client)

      client =
        Claudio.Client.new(%{
          token: "test-token",
          version: "2023-06-01"
        })

      # Default connect timeout is 60 seconds
      assert client.options[:connect_options][:timeout] == 60_000

      # Default receive timeout is 120 seconds
      assert client.options[:receive_timeout] == 120_000
    end

    test "respects custom timeout configuration" do
      Application.put_env(:claudio, Claudio.Client,
        timeout: 30_000,
        recv_timeout: 180_000
      )

      client =
        Claudio.Client.new(%{
          token: "test-token",
          version: "2023-06-01"
        })

      # Custom connect timeout is 30 seconds
      assert client.options[:connect_options][:timeout] == 30_000

      # Custom receive timeout is 180 seconds
      assert client.options[:receive_timeout] == 180_000
    end

    test "can be configured independently" do
      Application.put_env(:claudio, Claudio.Client, timeout: 45_000)

      client =
        Claudio.Client.new(%{
          token: "test-token",
          version: "2023-06-01"
        })

      # Custom connect timeout
      assert client.options[:connect_options][:timeout] == 45_000

      # Default receive timeout
      assert client.options[:receive_timeout] == 120_000
    end
  end

  describe "client creation" do
    test "creates client with required fields" do
      client =
        Claudio.Client.new(%{
          token: "test-token",
          version: "2023-06-01"
        })

      assert client.options[:base_url] == "https://api.anthropic.com/v1/"

      # Req stores headers as a map with list values
      assert client.headers["x-api-key"] == ["test-token"]
      assert client.headers["anthropic-version"] == ["2023-06-01"]
      assert client.headers["user-agent"] == ["claudio"]
    end

    test "creates client with beta features" do
      client =
        Claudio.Client.new(%{
          token: "test-token",
          version: "2023-06-01",
          beta: ["prompt-caching-2024-07-31", "token-counting-2024-11-01"]
        })

      assert client.headers["anthropic-beta"] == [
               "prompt-caching-2024-07-31,token-counting-2024-11-01"
             ]
    end

    test "creates client with custom endpoint" do
      client =
        Claudio.Client.new(
          %{
            token: "test-token",
            version: "2023-06-01"
          },
          "https://custom.endpoint.com/v1/"
        )

      assert client.options[:base_url] == "https://custom.endpoint.com/v1/"
    end

    test "uses default API version from app config" do
      Application.put_env(:claudio, :claudio, default_api_version: "2024-01-01")

      client =
        Claudio.Client.new(%{
          token: "test-token"
        })

      assert client.headers["anthropic-version"] == ["2024-01-01"]

      # Clean up
      Application.delete_env(:claudio, :claudio)
    end
  end

  describe "Bearer / OAuth auth (S8)" do
    test "auth_type: :bearer sends an Authorization header and no x-api-key" do
      client =
        Claudio.Client.new(%{
          token: "oauth-token-xyz",
          version: "2023-06-01",
          auth_type: :bearer
        })

      assert client.headers["authorization"] == ["Bearer oauth-token-xyz"]
      assert client.headers["x-api-key"] == nil
    end

    test "default auth still sends x-api-key and no Authorization (backward compatible)" do
      client = Claudio.Client.new(%{token: "test-token", version: "2023-06-01"})

      assert client.headers["x-api-key"] == ["test-token"]
      assert client.headers["authorization"] == nil
    end

    test "auth_type: :api_key is explicit x-api-key" do
      client =
        Claudio.Client.new(%{token: "test-token", version: "2023-06-01", auth_type: :api_key})

      assert client.headers["x-api-key"] == ["test-token"]
      assert client.headers["authorization"] == nil
    end

    test "bearer auth composes with anthropic-version and beta headers" do
      client =
        Claudio.Client.new(%{
          token: "tok",
          version: "2023-06-01",
          auth_type: :bearer,
          beta: ["oauth-2025-04-20"]
        })

      assert client.headers["authorization"] == ["Bearer tok"]
      assert client.headers["anthropic-version"] == ["2023-06-01"]
      assert client.headers["anthropic-beta"] == ["oauth-2025-04-20"]
    end
  end

  describe "with_betas/2" do
    test "is a no-op for an empty beta list" do
      client = Claudio.Client.new(%{token: "t", version: "2023-06-01", beta: ["a-2025-01-01"]})
      assert Claudio.Client.with_betas(client, []) == client
    end

    test "unions new betas onto the existing header" do
      client = Claudio.Client.new(%{token: "t", version: "2023-06-01", beta: ["a-2025-01-01"]})
      merged = Claudio.Client.with_betas(client, ["b-2025-01-01"])
      assert merged.headers["anthropic-beta"] == ["a-2025-01-01,b-2025-01-01"]
    end

    test "sets the header when the client had none" do
      client = Claudio.Client.new(%{token: "t", version: "2023-06-01"})
      merged = Claudio.Client.with_betas(client, ["b-2025-01-01"])
      assert merged.headers["anthropic-beta"] == ["b-2025-01-01"]
    end

    test "dedups betas already present" do
      client = Claudio.Client.new(%{token: "t", version: "2023-06-01", beta: ["a-2025-01-01"]})
      merged = Claudio.Client.with_betas(client, ["a-2025-01-01", "b-2025-01-01"])
      assert merged.headers["anthropic-beta"] == ["a-2025-01-01,b-2025-01-01"]
    end

    test "trims and drops blank/whitespace-only betas before merging" do
      client = Claudio.Client.new(%{token: "t", version: "2023-06-01", beta: ["a-2025-01-01"]})
      merged = Claudio.Client.with_betas(client, [" b-2025-01-01 ", "", "   "])
      assert merged.headers["anthropic-beta"] == ["a-2025-01-01,b-2025-01-01"]
    end
  end

  describe "documented app config (pre-release audit)" do
    setup do
      saved =
        for key <- [:default_api_version, :default_beta_features],
            do: {key, Application.get_env(:claudio, key)}

      saved_client = Application.get_env(:claudio, Claudio.Client)

      on_exit(fn ->
        for {key, value} <- saved do
          if value,
            do: Application.put_env(:claudio, key, value),
            else: Application.delete_env(:claudio, key)
        end

        if saved_client,
          do: Application.put_env(:claudio, Claudio.Client, saved_client),
          else: Application.delete_env(:claudio, Claudio.Client)
      end)
    end

    test "config :claudio, default_api_version / default_beta_features (the README form) apply" do
      Application.put_env(:claudio, :default_api_version, "2099-01-01")
      Application.put_env(:claudio, :default_beta_features, ["x-2026-01-01"])

      client = Claudio.Client.new(%{token: "t"})

      assert client.headers["anthropic-version"] == ["2099-01-01"]
      assert client.headers["anthropic-beta"] == ["x-2026-01-01"]
    end

    # Req logs each retry at :warning.
    @tag :capture_log
    test "retry: [...] retries a POST on a retryable status" do
      bypass = Bypass.open()
      count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(count, 1, 1)

        if :counters.get(count, 1) == 1 do
          Plug.Conn.resp(conn, 503, "")
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(ok_message_body()))
        end
      end)

      Application.put_env(:claudio, Claudio.Client,
        retry: [max_retries: 2, delay: 1, max_delay: 5]
      )

      client =
        Claudio.Client.new(
          %{token: "t", version: "2023-06-01"},
          "http://localhost:#{bypass.port}/"
        )

      request =
        Request.new("x")
        |> Request.add_message(:user, "hi")
        |> Request.set_max_tokens(8)

      assert {:ok, %Claudio.Messages.Response{}} = Claudio.Messages.create(client, request)
      assert :counters.get(count, 1) == 2
    end

    test "retryable statuses include 429, 5xx and 529 (overloaded); 400 is not" do
      for status <- [408, 429, 500, 502, 503, 504, 529] do
        assert Claudio.Client.retryable?(nil, %Req.Response{status: status})
      end

      refute Claudio.Client.retryable?(nil, %Req.Response{status: 400})
      assert Claudio.Client.retryable?(nil, %Req.TransportError{reason: :timeout})
    end
  end

  describe "Retry-After" do
    @tag :capture_log
    test "529 with retry-after: 1 waits ~1s even with a small configured delay" do
      gap = measure_retry_gap(529, [{"retry-after", "1"}], retry: [delay: 10, max_retries: 1])
      assert gap >= 950
    end

    @tag :capture_log
    test "429 retry-after wins over delay:" do
      gap = measure_retry_gap(429, [{"retry-after", "1"}], retry: [delay: 10, max_retries: 1])
      assert gap >= 950
    end

    @tag :capture_log
    test "without retry-after the configured delay is used" do
      gap = measure_retry_gap(503, [], retry: [delay: 10, max_retries: 1])
      assert gap < 500
    end

    @tag :capture_log
    test "an unparseable retry-after falls back to the backoff" do
      gap = measure_retry_gap(429, [{"retry-after", "soon"}], retry: [delay: 10, max_retries: 1])
      assert gap < 500
    end
  end

  # Serves the first response from a Req adapter rather than Bypass: Plug cannot write a 529
  # (unknown status), which would silently turn it into a 500.
  defp measure_retry_gap(status, headers, client_opts) do
    {:ok, times} = Agent.start_link(fn -> [] end)

    client =
      Map.new([token: "t", version: "2023-06-01"] ++ client_opts)
      |> Claudio.Client.new("http://localhost:1/")
      |> Req.merge(adapter: __MODULE__.RetryProbeAdapter)
      |> Req.Request.put_private(:retry_probe, {times, status, headers})

    request = Request.new("x") |> Request.add_message(:user, "hi") |> Request.set_max_tokens(8)
    assert {:ok, _} = Claudio.Messages.create(client, request)
    [second, first] = Agent.get(times, & &1)
    second - first
  end

  defp ok_message_body do
    %{
      "id" => "m",
      "type" => "message",
      "role" => "assistant",
      "model" => "x",
      "content" => [],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  describe "re-audit: retry and streaming" do
    setup do
      saved = Application.get_env(:claudio, Claudio.Client)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:claudio, Claudio.Client, saved),
          else: Application.delete_env(:claudio, Claudio.Client)
      end)
    end

    test "streaming requests are not retried and leave no stray messages in the mailbox" do
      bypass = Bypass.open()
      count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(count, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          503,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{"type" => "overloaded_error", "message" => "busy"}
          })
        )
      end)

      Application.put_env(:claudio, Claudio.Client, retry: [max_retries: 2, delay: 1])

      client =
        Claudio.Client.new(
          %{token: "t", version: "2023-06-01"},
          "http://localhost:#{bypass.port}/"
        )

      request =
        Request.new("x")
        |> Request.add_message(:user, "hi")
        |> Request.set_max_tokens(8)
        |> Request.enable_streaming()

      assert {:error, %Claudio.APIError{status_code: 503}} =
               Claudio.Messages.create(client, request)

      assert :counters.get(count, 1) == 1
      refute_receive _, 100
    end

    test "retry: false disables retries entirely (Req's GET/HEAD default too)" do
      Application.put_env(:claudio, Claudio.Client, retry: false)
      client = Claudio.Client.new(%{token: "t", version: "2023-06-01"})

      assert client.options[:retry] == false
    end
  end

  describe "per-client options vs app env" do
    setup do
      saved = Application.get_env(:claudio, Claudio.Client)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:claudio, Claudio.Client, saved),
          else: Application.delete_env(:claudio, Claudio.Client)
      end)
    end

    test "per-client values override the app env; unset keys fall back to it" do
      Application.put_env(:claudio, Claudio.Client,
        timeout: 30_000,
        recv_timeout: 180_000,
        retry: [max_retries: 5]
      )

      client =
        Claudio.Client.new(%{token: "t", version: "2023-06-01", timeout: 1_000, retry: false})

      assert client.options[:connect_options][:timeout] == 1_000
      assert client.options[:receive_timeout] == 180_000
      assert client.options[:retry] == false
    end

    test "an invalid app-env retry value raises instead of being ignored" do
      Application.put_env(:claudio, Claudio.Client, retry: :yes)

      assert_raise ArgumentError, ~r/:retry .*:yes/, fn ->
        Claudio.Client.new(%{token: "t", version: "2023-06-01"})
      end
    end

    test "an explicit nil falls back to the app env, like an omitted key" do
      Application.put_env(:claudio, Claudio.Client, timeout: 30_000, retry: [max_retries: 5])

      client =
        Claudio.Client.new(%{token: "t", version: "2023-06-01", timeout: nil, retry: nil})

      assert client.options[:connect_options][:timeout] == 30_000
      assert client.options[:max_retries] == 5
    end

    test "an invalid app-env timeout raises" do
      Application.put_env(:claudio, Claudio.Client, recv_timeout: "120000")

      assert_raise ArgumentError, ~r/:recv_timeout .*"120000"/, fn ->
        Claudio.Client.new(%{token: "t", version: "2023-06-01"})
      end
    end
  end
end

defmodule Claudio.ClientOptionsTest do
  # Per-client options never touch the application env, so these run async.
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request

  defp new(opts, endpoint \\ "https://api.anthropic.com/v1/"),
    do: Claudio.Client.new(Map.merge(%{token: "t", version: "2023-06-01"}, opts), endpoint)

  describe "per-client timeouts" do
    test "timeout and recv_timeout set connect and receive timeouts" do
      client = new(%{timeout: 5_000, recv_timeout: 7_000})

      assert client.options[:connect_options][:timeout] == 5_000
      assert client.options[:receive_timeout] == 7_000
    end

    test "unset timeouts keep the defaults" do
      client = new(%{timeout: 5_000})

      assert client.options[:connect_options][:timeout] == 5_000
      assert client.options[:receive_timeout] == 120_000
    end

    test ":infinity and 0 are accepted" do
      client = new(%{timeout: 0, recv_timeout: :infinity})

      assert client.options[:connect_options][:timeout] == 0
      assert client.options[:receive_timeout] == :infinity
    end

    test "a non-integer or negative timeout raises, naming the option and value" do
      assert_raise ArgumentError, ~r/:timeout .*"5000"/, fn -> new(%{timeout: "5000"}) end
      assert_raise ArgumentError, ~r/:recv_timeout .*-1/, fn -> new(%{recv_timeout: -1}) end
    end
  end

  describe "per-client retry" do
    # Req logs each retry at :warning.
    @tag :capture_log
    test "retry: [...] retries a POST on a retryable status" do
      bypass = Bypass.open()
      count = :counters.new(1, [:atomics])
      test_pid = self()

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(count, 1, 1)

        if :counters.get(count, 1) == 1 do
          # 503, not 529: Plug rejects 529 as an unknown status when the response is written,
          # Bypass answers 500 instead (also retryable), and the test passes without serving
          # the status it meant to. send_resp writes here, so a bad status raises before the
          # {:served, _} message. 529 retryability is covered by retryable?/2.
          conn =
            Plug.Conn.send_resp(
              conn,
              503,
              ~s({"type":"error","error":{"type":"overloaded_error","message":"busy"}})
            )

          send(test_pid, {:served, 503})
          conn
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "id" => "msg_1",
              "type" => "message",
              "role" => "assistant",
              "model" => "x",
              "content" => [],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
            })
          )
        end
      end)

      client =
        new(
          %{retry: [max_retries: 2, delay: 1, max_delay: 5]},
          "http://localhost:#{bypass.port}/"
        )

      request =
        Request.new("x")
        |> Request.add_message(:user, "hi")
        |> Request.set_max_tokens(8)

      assert {:ok, %Claudio.Messages.Response{}} = Claudio.Messages.create(client, request)
      assert :counters.get(count, 1) == 2
      assert_received {:served, 503}
    end

    test "retry: true uses 3 retries; retry: false disables retries" do
      assert new(%{retry: true}).options[:max_retries] == 3
      assert new(%{retry: false}).options[:retry] == false
    end

    test "an invalid retry value raises, naming the value" do
      assert_raise ArgumentError, ~r/:retry .*:yes/, fn -> new(%{retry: :yes}) end
    end

    test "an unknown retry option raises" do
      assert_raise ArgumentError, ~r/max_retry/, fn -> new(%{retry: [max_retry: 2]}) end
    end
  end

  describe "retry value validation" do
    for {key, bad} <- [delay: "1s", delay: -5, max_delay: 1.5, max_retries: -1, max_retries: "3"] do
      test "#{key}: #{inspect(bad)} raises at new/2" do
        assert_raise ArgumentError,
                     ~r/:retry #{inspect(unquote(key))} must be a non-negative integer/,
                     fn ->
                       new(%{retry: [{unquote(key), unquote(bad)}]})
                     end
      end
    end

    test "valid values pass" do
      assert %Req.Request{} =
               new(%{retry: [delay: 0, max_retries: 0, max_delay: 10]})
    end
  end

  describe "new/2 config validation" do
    test "token: nil raises and mentions ANTHROPIC_API_KEY" do
      assert_raise ArgumentError, ~r/:token must be a non-empty string.*ANTHROPIC_API_KEY/s, fn ->
        Claudio.Client.new(%{token: nil})
      end
    end

    test "a missing token raises" do
      assert_raise ArgumentError, ~r/:token/, fn -> Claudio.Client.new(%{}) end
    end

    test "unknown keys raise with the allowed list" do
      assert_raise ArgumentError, ~r/unknown option :api_key; allowed: :token/, fn ->
        Claudio.Client.new(%{api_key: "x"})
      end
    end

    test "a keyword list is accepted" do
      client = Claudio.Client.new(token: "t", timeout: 5_000)
      assert Req.Request.get_header(client, "x-api-key") == ["t"]
    end

    test "version: nil falls back to the default version" do
      client = Claudio.Client.new(%{token: "t", version: nil})
      assert Req.Request.get_header(client, "anthropic-version") == ["2023-06-01"]
    end
  end
end
