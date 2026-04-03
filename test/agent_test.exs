defmodule Claudio.AgentTest do
  use ExUnit.Case, async: true

  alias Claudio.Agent
  alias Claudio.Messages.Request
  alias Claudio.Tools

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01"},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  defp json_response(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp end_turn_response(text) do
    %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-5-20250929",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
    }
  end

  defp tool_use_response(tool_use_id, tool_name, input) do
    %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-5-20250929",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => tool_use_id,
          "name" => tool_name,
          "input" => input
        }
      ],
      "stop_reason" => "tool_use",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 15, "output_tokens" => 30}
    }
  end

  defp base_request do
    Request.new("claude-sonnet-4-5-20250929")
    |> Request.add_message(:user, "Hello")
    |> Request.set_max_tokens(1024)
  end

  describe "run/4" do
    test "returns immediately on end_turn response", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        json_response(conn, end_turn_response("Hello there!"))
      end)

      {:ok, response, messages} = Agent.run(client, base_request(), %{})

      assert response.stop_reason == :end_turn
      assert Claudio.Messages.Response.get_text(response) == "Hello there!"
      assert length(messages) == 2
      assert hd(messages)["role"] == "user"
      assert List.last(messages)["role"] == "assistant"
    end

    test "executes single tool call then returns", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "get_weather", %{"location" => "SF"})
            )

          2 ->
            json_response(conn, end_turn_response("It's 72°F and sunny in SF."))
        end
      end)

      handlers = %{
        "get_weather" => fn %{"location" => loc} ->
          {:ok, "72°F and sunny in #{loc}"}
        end
      }

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("get_weather", "Get weather", %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          })
        )

      {:ok, response, messages} = Agent.run(client, request, handlers)

      assert response.stop_reason == :end_turn
      assert Claudio.Messages.Response.get_text(response) == "It's 72°F and sunny in SF."
      assert :counters.get(call_count, 1) == 2

      # Messages: user, assistant (tool_use), user (tool_result), assistant (final)
      assert length(messages) == 4
    end

    test "handles multiple tool calls in sequence", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "get_weather", %{"location" => "SF"})
            )

          2 ->
            json_response(
              conn,
              tool_use_response("toolu_2", "get_weather", %{"location" => "NYC"})
            )

          3 ->
            json_response(conn, end_turn_response("SF: 72°F, NYC: 55°F"))
        end
      end)

      handlers = %{
        "get_weather" => fn %{"location" => loc} ->
          temps = %{"SF" => "72°F", "NYC" => "55°F"}
          {:ok, Map.get(temps, loc, "unknown")}
        end
      }

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("get_weather", "Get weather", %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          })
        )

      {:ok, response, messages} = Agent.run(client, request, handlers)

      assert response.stop_reason == :end_turn
      assert :counters.get(call_count, 1) == 3
      # user, assistant, tool_result, assistant, tool_result, assistant
      assert length(messages) == 6
    end

    test "returns error on max_turns exceeded", %{client: client, bypass: bypass} do
      # Always return tool_use — loop should stop at max_turns
      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        json_response(
          conn,
          tool_use_response("toolu_x", "get_weather", %{"location" => "SF"})
        )
      end)

      handlers = %{
        "get_weather" => fn _input -> {:ok, "72°F"} end
      }

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("get_weather", "Get weather", %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          })
        )

      assert {:error, :max_turns_exceeded, response, messages} =
               Agent.run(client, request, handlers, max_turns: 2)

      assert response.stop_reason == :tool_use
      assert length(messages) > 0
    end

    test "handles unknown tool gracefully", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "unknown_tool", %{"foo" => "bar"})
            )

          2 ->
            json_response(conn, end_turn_response("Sorry, I couldn't use that tool."))
        end
      end)

      {:ok, response, _messages} = Agent.run(client, base_request(), %{})

      assert response.stop_reason == :end_turn
    end

    test "handles tool handler errors", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "failing_tool", %{})
            )

          2 ->
            json_response(conn, end_turn_response("The tool failed."))
        end
      end)

      handlers = %{
        "failing_tool" => fn _input -> {:error, "Something went wrong"} end
      }

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("failing_tool", "A tool that fails", %{
            "type" => "object",
            "properties" => %{}
          })
        )

      {:ok, response, _messages} = Agent.run(client, request, handlers)
      assert response.stop_reason == :end_turn
    end

    test "handles tool handler exceptions", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "crashing_tool", %{})
            )

          2 ->
            json_response(conn, end_turn_response("Tool crashed."))
        end
      end)

      handlers = %{
        "crashing_tool" => fn _input -> raise "boom" end
      }

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("crashing_tool", "Crashes", %{
            "type" => "object",
            "properties" => %{}
          })
        )

      {:ok, response, _messages} = Agent.run(client, request, handlers)
      assert response.stop_reason == :end_turn
    end

    test "handles tool handler throw", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "throwing_tool", %{})
            )

          2 ->
            json_response(conn, end_turn_response("Handled."))
        end
      end)

      handlers = %{
        "throwing_tool" => fn _input -> throw(:boom) end
      }

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("throwing_tool", "Throws", %{
            "type" => "object",
            "properties" => %{}
          })
        )

      {:ok, response, _messages} = Agent.run(client, request, handlers)
      assert response.stop_reason == :end_turn
    end

    test "handles tool handler exit", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "exiting_tool", %{})
            )

          2 ->
            json_response(conn, end_turn_response("Handled."))
        end
      end)

      handlers = %{
        "exiting_tool" => fn _input -> exit(:shutdown) end
      }

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("exiting_tool", "Exits", %{
            "type" => "object",
            "properties" => %{}
          })
        )

      {:ok, response, _messages} = Agent.run(client, request, handlers)
      assert response.stop_reason == :end_turn
    end

    test "calls on_tool_call callback", %{client: client, bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            json_response(
              conn,
              tool_use_response("toolu_1", "get_weather", %{"location" => "SF"})
            )

          2 ->
            json_response(conn, end_turn_response("Done."))
        end
      end)

      test_pid = self()

      handlers = %{
        "get_weather" => fn _input -> {:ok, "72°F"} end
      }

      on_tool_call = fn tool_use, result ->
        send(test_pid, {:tool_called, tool_use.name, result})
      end

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("get_weather", "Get weather", %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          })
        )

      {:ok, _response, _messages} =
        Agent.run(client, request, handlers, on_tool_call: on_tool_call)

      assert_receive {:tool_called, "get_weather", {:ok, "72°F"}}
    end

    test "propagates API errors", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          401,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{
              "type" => "authentication_error",
              "message" => "invalid x-api-key"
            }
          })
        )
      end)

      assert {:error, %Claudio.APIError{type: :authentication_error}} =
               Agent.run(client, base_request(), %{})
    end
  end
end
