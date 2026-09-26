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

  defp thinking_tool_use_response(tool_use_id, tool_name, input, signature) do
    %{
      "id" => "msg_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-5-20250929",
      "content" => [
        %{"type" => "thinking", "thinking" => "Let me think", "signature" => signature},
        %{"type" => "tool_use", "id" => tool_use_id, "name" => tool_name, "input" => input}
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

    test "preserves thinking signature when replaying the assistant turn", %{
      client: client,
      bypass: bypass
    } do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 ->
            json_response(
              conn,
              thinking_tool_use_response(
                "toolu_1",
                "get_weather",
                %{"location" => "SF"},
                "sig_xyz"
              )
            )

          2 ->
            json_response(conn, end_turn_response("Done"))
        end
      end)

      handlers = %{"get_weather" => fn %{"location" => loc} -> {:ok, "72F in #{loc}"} end}

      request =
        base_request()
        |> Request.add_tool(
          Tools.define_tool("get_weather", "Get weather", %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          })
        )

      {:ok, _response, messages} = Agent.run(client, request, handlers)

      thinking_block =
        messages
        |> Enum.filter(&(&1["role"] == "assistant"))
        |> Enum.flat_map(fn m -> List.wrap(m["content"]) end)
        |> Enum.find(fn b -> is_map(b) and b["type"] == "thinking" end)

      assert thinking_block != nil
      assert thinking_block["signature"] == "sig_xyz"
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

  describe "run/4 toolsets, containers and pause_turn (S14)" do
    defp message(content, stop_reason, extra \\ %{}) do
      Map.merge(
        %{
          "id" => "msg_#{System.unique_integer([:positive])}",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-opus-5-5",
          "content" => content,
          "stop_reason" => stop_reason,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        extra
      )
    end

    defp member(id, name, toolset \\ "computer") do
      %{
        "type" => "tool_use",
        "id" => id,
        "name" => name,
        "input" => %{},
        "toolset_name" => toolset
      }
    end

    defp plain(id, name), do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}}

    # Serves `responses` in order and forwards every request body to the test process.
    defp serve(bypass, responses) do
      test_pid = self()
      count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        :counters.add(count, 1, 1)
        json_response(conn, Enum.at(responses, :counters.get(count, 1) - 1))
      end)
    end

    defp tool_results(body) do
      body["messages"] |> List.last() |> Map.fetch!("content")
    end

    test "pair dispatch: a custom screenshot tool never gets toolset calls (Review Focus 2)", %{
      client: client,
      bypass: bypass
    } do
      serve(bypass, [
        message([member("t1", "screenshot"), plain("t2", "screenshot")], "tool_use"),
        message([%{"type" => "text", "text" => "done"}], "end_turn")
      ])

      handlers = %{
        "computer" => fn member, input -> {:ok, "computer:#{member}:#{map_size(input)}"} end,
        "screenshot" => fn _input -> {:ok, "custom"} end
      }

      assert {:ok, _response, _messages} = Agent.run(client, base_request(), handlers)

      assert_received {:request_body, _first}
      assert_received {:request_body, second}

      assert [
               %{
                 "tool_use_id" => "t1",
                 "content" => "computer:screenshot:0",
                 "toolset_name" => "computer"
               },
               %{"tool_use_id" => "t2", "content" => "custom"} = custom
             ] = tool_results(second)

      refute Map.has_key?(custom, "toolset_name")

      # The replayed assistant turn keeps toolset_name (a stripped one is a 400).
      assistant = Enum.at(second["messages"], -2)
      assert %{"toolset_name" => "computer"} = hd(assistant["content"])
    end

    test "a missing toolset handler is an error result with toolset_name echoed", %{
      client: client,
      bypass: bypass
    } do
      serve(bypass, [
        message([member("t1", "navigate", "browser")], "tool_use"),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      assert {:ok, _, _} = Agent.run(client, base_request(), %{})
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert [
               %{
                 "is_error" => true,
                 "content" => "Unknown toolset: browser",
                 "toolset_name" => "browser"
               }
             ] = tool_results(second)
    end

    test "batch halt: later calls of the failing toolset are skipped; others still run (Review Focus 3)",
         %{client: client, bypass: bypass} do
      serve(bypass, [
        message(
          [
            member("c1", "left_click"),
            member("c2", "type"),
            plain("p1", "lookup"),
            member("b1", "navigate", "browser"),
            member("c3", "key"),
            member("c4", "screenshot")
          ],
          "tool_use"
        ),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      test_pid = self()

      handlers = %{
        "computer" => fn
          "left_click", _ -> {:ok, "clicked"}
          "type", _ -> {:error, "keyboard unavailable"}
          other, _ -> send(test_pid, {:ran, other}) && {:ok, "ran"}
        end,
        "browser" => fn "navigate", _ -> {:ok, "navigated"} end,
        "lookup" => fn _ -> {:ok, "found"} end
      }

      on_tool_call = fn tool_use, _result -> send(test_pid, {:observed, tool_use.id}) end

      assert {:ok, _, _} = Agent.run(client, base_request(), handlers, on_tool_call: on_tool_call)
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert [
               %{"tool_use_id" => "c1", "content" => "clicked"},
               %{"tool_use_id" => "c2", "is_error" => true, "content" => "keyboard unavailable"},
               %{"tool_use_id" => "p1", "content" => "found"},
               %{"tool_use_id" => "b1", "content" => "navigated"},
               %{
                 "tool_use_id" => "c3",
                 "is_error" => true,
                 "content" => "Not executed: an earlier computer action in this turn failed.",
                 "toolset_name" => "computer"
               },
               %{
                 "tool_use_id" => "c4",
                 "is_error" => true,
                 "content" => "Not executed: an earlier computer action in this turn failed."
               }
             ] = tool_results(second)

      refute_received {:ran, "key"}
      refute_received {:ran, "screenshot"}
      # on_tool_call sees executed calls only.
      for id <- ["c1", "c2", "p1", "b1"], do: assert_received({:observed, ^id})
      refute_received {:observed, "c3"}
      refute_received {:observed, "c4"}
    end

    test "the response container is carried to the next request", %{
      client: client,
      bypass: bypass
    } do
      container = %{"id" => "container_01", "expires_at" => "2026-09-26T19:00:00Z"}

      serve(bypass, [
        message([plain("t1", "lookup")], "tool_use", %{"container" => container}),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      assert {:ok, _, _} =
               Agent.run(client, base_request(), %{"lookup" => fn _ -> {:ok, "x"} end})

      assert_received {:request_body, first}
      assert_received {:request_body, second}

      refute Map.has_key?(first, "container")
      assert second["container"] == "container_01"
    end

    test "a map container (e.g. with skills) keeps its keys and gains the id", %{
      client: client,
      bypass: bypass
    } do
      serve(bypass, [
        message([plain("t1", "lookup")], "tool_use", %{"container" => %{"id" => "container_01"}}),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      skills = [%{"type" => "anthropic", "skill_id" => "xlsx"}]
      request = Request.set_container(base_request(), %{"skills" => skills})

      assert {:ok, _, _} = Agent.run(client, request, %{"lookup" => fn _ -> {:ok, "x"} end})
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert second["container"] == %{"id" => "container_01", "skills" => skills}
    end

    test "an atom-keyed container keeps a single id key", %{client: client, bypass: bypass} do
      test_pid = self()
      count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw_body, body})
        :counters.add(count, 1, 1)

        response =
          if :counters.get(count, 1) == 1,
            do: message([plain("t1", "lookup")], "tool_use", %{"container" => %{"id" => "new"}}),
            else: message([%{"type" => "text", "text" => "ok"}], "end_turn")

        json_response(conn, response)
      end)

      request = Request.set_container(base_request(), %{id: "old", skills: []})

      assert {:ok, _, _} = Agent.run(client, request, %{"lookup" => fn _ -> {:ok, "x"} end})
      assert_received {:raw_body, _}
      assert_received {:raw_body, second}

      [_, container_json] = Regex.run(~r/"container":(\{[^}]*\})/, second)
      assert length(Regex.scan(~r/"id"/, container_json)) == 1
      assert Jason.decode!(container_json) == %{"id" => "new", "skills" => []}
    end

    test "an unknown toolset's failures don't halt it (no halt contract) and don't crash", %{
      client: client,
      bypass: bypass
    } do
      serve(bypass, [
        message([member("x1", "run", "terminal"), member("x2", "run", "terminal")], "tool_use"),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      handlers = %{"terminal" => fn _, _ -> {:error, "boom"} end}

      assert {:ok, _, _} = Agent.run(client, base_request(), handlers)
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert [
               %{"tool_use_id" => "x1", "content" => "boom", "is_error" => true},
               %{"tool_use_id" => "x2", "content" => "boom", "is_error" => true}
             ] = tool_results(second)
    end

    test "wrong arity is an error result; list content is passed through", %{
      client: client,
      bypass: bypass
    } do
      image = [%{"type" => "text", "text" => "screen"}]

      serve(bypass, [
        message([member("c1", "screenshot"), plain("p1", "lookup")], "tool_use"),
        message([%{"type" => "text", "text" => "ok"}], "end_turn")
      ])

      handlers = %{
        "computer" => fn _, _ -> {:ok, image} end,
        "lookup" => fn _, _ -> {:ok, "x"} end
      }

      assert {:ok, _, _} = Agent.run(client, base_request(), handlers)
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert [
               %{"tool_use_id" => "c1", "content" => ^image},
               %{
                 "tool_use_id" => "p1",
                 "is_error" => true,
                 "content" => "Handler for lookup must take (input)"
               }
             ] = tool_results(second)
    end

    test "a handler returning anything but {:ok, _} / {:error, _} raises a clear ArgumentError",
         %{
           client: client,
           bypass: bypass
         } do
      serve(bypass, [message([plain("t1", "lookup"), member("c1", "screenshot")], "tool_use")])

      assert_raise ArgumentError,
                   ~r/handler for tool "lookup" must return \{:ok, content\} or \{:error, reason\}; got :ok/,
                   fn ->
                     Agent.run(client, base_request(), %{"lookup" => fn _ -> :ok end})
                   end

      serve(bypass, [message([member("c1", "screenshot")], "tool_use")])

      assert_raise ArgumentError,
                   ~r/handler for toolset "computer" must return .*got "png"/,
                   fn ->
                     Agent.run(client, base_request(), %{"computer" => fn _, _ -> "png" end})
                   end
    end

    test "pause_turn resumes with the assistant content and no user message", %{
      client: client,
      bypass: bypass
    } do
      paused = [
        %{"type" => "server_tool_use", "id" => "srv_1", "name" => "advisor", "input" => %{}}
      ]

      serve(bypass, [
        message(paused, "pause_turn"),
        message([%{"type" => "text", "text" => "done"}], "end_turn")
      ])

      assert {:ok, %{stop_reason: :end_turn}, _} = Agent.run(client, base_request(), %{})
      assert_received {:request_body, _}
      assert_received {:request_body, second}

      assert %{"role" => "assistant", "content" => ^paused} = List.last(second["messages"])
    end

    test "max_turns caps model calls: max_turns: 2 → exactly 2 calls (doc fix)", %{
      client: client,
      bypass: bypass
    } do
      serve(bypass, List.duplicate(message([plain("t", "lookup")], "tool_use"), 5))

      assert {:error, :max_turns_exceeded, _, _} =
               Agent.run(client, base_request(), %{"lookup" => fn _ -> {:ok, "x"} end},
                 max_turns: 2
               )

      assert_received {:request_body, _}
      assert_received {:request_body, _}
      refute_received {:request_body, _}
    end

    test "pause_turn then tool_use: the history keeps both assistant turns in order", %{
      client: client,
      bypass: bypass
    } do
      paused = [
        %{"type" => "server_tool_use", "id" => "srv_1", "name" => "advisor", "input" => %{}}
      ]

      serve(bypass, [
        message(paused, "pause_turn"),
        message([plain("t1", "lookup")], "tool_use"),
        message([%{"type" => "text", "text" => "done"}], "end_turn")
      ])

      assert {:ok, _, _} =
               Agent.run(client, base_request(), %{"lookup" => fn _ -> {:ok, "x"} end})

      assert_received {:request_body, _}
      assert_received {:request_body, _}
      assert_received {:request_body, third}

      # Two consecutive assistant messages are accepted by the API (probe T6, spec F19).
      assert Enum.map(third["messages"], & &1["role"]) ==
               ["user", "assistant", "assistant", "user"]

      assert [_, %{"content" => ^paused}, %{"content" => [%{"id" => "t1"}]}, _] =
               third["messages"]
    end

    test "endless pause_turn stops at max_turns (Review Focus 5)", %{
      client: client,
      bypass: bypass
    } do
      paused = message([%{"type" => "text", "text" => "…"}], "pause_turn")
      serve(bypass, List.duplicate(paused, 5))

      assert {:error, :max_turns_exceeded, %{stop_reason: :pause_turn}, _messages} =
               Agent.run(client, base_request(), %{}, max_turns: 2)
    end
  end
end
