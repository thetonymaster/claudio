defmodule Claudio.ClientTest do
  use ExUnit.Case, async: true

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
end
