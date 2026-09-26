defmodule Claudio.Agent do
  @moduledoc """
  Stateless agent loop utility for tool-calling workflows.

  Runs the tool-calling loop: send request → check for tool uses →
  execute handlers → append results → repeat until done.

  This is a pure function — no GenServer, no process. State management
  (conversation history, persistence) is the caller's responsibility.

  ## Example

      alias Claudio.{Agent, Messages.Request, Tools}

      # Define tools and handlers
      weather_tool = Tools.define_tool("get_weather", "Get weather", %{
        "type" => "object",
        "properties" => %{"location" => %{"type" => "string"}},
        "required" => ["location"]
      })

      handlers = %{
        "get_weather" => fn %{"location" => loc} ->
          {:ok, "72°F and sunny in \#{loc}"}
        end
      }

      # Build request
      request = Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "What's the weather in SF?")
      |> Request.add_tool(weather_tool)
      |> Request.set_max_tokens(1024)

      # Run the agent loop
      {:ok, response, messages} = Agent.run(client, request, handlers)

      # response is the final Response struct
      # messages is the full conversation history (for continuing later)

  ## Client toolsets

  Calls from `Request.add_computer_toolset/2` / `add_browser_toolset/2` carry a
  `toolset_name` and go **only** to the handler keyed by it, as `fn member, input -> … end`
  (e.g. `%{"computer" => fn "screenshot", _ -> {:ok, [image_block]} end}`); a plain tool
  with the same name as a member never receives them. Results echo `toolset_name`. If an
  action fails, the toolset's later actions in that turn are not run and are answered
  with the documented halt text (`Claudio.Tools.halt_result/1`).

  ## Programmatic tool calling and pauses

  A response `container` is carried to the next request (required to continue calls made
  from code execution). A `pause_turn` is resumed automatically by resending the
  assistant turn; it counts toward `:max_turns`.

  ## Options

    - `:max_turns` — Maximum model calls (default: 10)
    - `:on_tool_call` — Optional callback `fn tool_use, result -> :ok end` for logging/observability
  """

  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}
  alias Claudio.Tools

  @type result :: {:ok, String.t() | [map()]} | {:error, String.t()}
  @type handler :: (map() -> result()) | (String.t(), map() -> result())
  @type handlers :: %{String.t() => handler()}

  @type run_result ::
          {:ok, Response.t(), [map()]}
          | {:error, :max_turns_exceeded, Response.t(), [map()]}
          | {:error, term()}

  @default_max_turns 10

  @doc """
  Runs the agent loop until the model stops requesting tools or max_turns is reached.

  `max_turns` caps the number of model calls. With `max_turns: 2` the model is called at
  most twice — the initial call plus one tool-result (or `pause_turn`) follow-up; if the
  second call still requests tools or pauses, the loop stops with `:max_turns_exceeded`.

  Returns `{:ok, final_response, messages}` on success, where `messages` is the
  full conversation history including all tool calls and results.

  Returns `{:error, :max_turns_exceeded, last_response, messages}` if the loop
  doesn't converge within `max_turns` tool round-trips.

  Returns `{:error, reason}` if the API call fails.
  """
  @spec run(Req.Request.t(), Request.t(), handlers(), keyword()) :: run_result()
  def run(client, %Request{} = request, tool_handlers, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    on_tool_call = Keyword.get(opts, :on_tool_call)

    loop(client, request, tool_handlers, max_turns, on_tool_call, 0)
  end

  # --- Private ---

  defp loop(client, request, handlers, max_turns, on_tool_call, turn) do
    case Messages.create(client, request) do
      {:ok, %Response{stop_reason: reason} = response}
      when reason in [:tool_use, :pause_turn] and turn + 1 >= max_turns ->
        messages =
          extract_messages(request) ++
            [%{"role" => "assistant", "content" => Response.to_assistant_content(response)}]

        {:error, :max_turns_exceeded, response, messages}

      {:ok, %Response{stop_reason: :tool_use} = response} ->
        tool_uses = Tools.extract_tool_uses(response)
        tool_results = execute_tools(tool_uses, handlers, on_tool_call)

        updated_request =
          request
          |> carry_container(response)
          |> Request.add_message(:assistant, Response.to_assistant_content(response))
          # tool_results is a list of tool_result maps — add_message accepts lists as content
          |> Request.add_message(:user, tool_results)

        loop(client, updated_request, handlers, max_turns, on_tool_call, turn + 1)

      {:ok, %Response{stop_reason: :pause_turn} = response} ->
        # A server tool (e.g. the advisor) paused a long turn: resend it unchanged so the
        # API continues it. Counts toward max_turns like a tool round trip.
        updated_request =
          request
          |> carry_container(response)
          |> Request.add_message(:assistant, Response.to_assistant_content(response))

        loop(client, updated_request, handlers, max_turns, on_tool_call, turn + 1)

      {:ok, %Response{} = response} ->
        messages =
          extract_messages(request) ++
            [%{"role" => "assistant", "content" => Response.to_assistant_content(response)}]

        {:ok, response, messages}

      {:error, _} = error ->
        error
    end
  end

  # Programmatic tool calling: continuing needs the container the calls run in. A map
  # container set by the caller (e.g. with "skills") keeps its other keys and gains the id.
  defp carry_container(request, %Response{container: container}) when is_map(container) do
    case Map.get(container, "id") || Map.get(container, :id) do
      nil -> request
      id -> Request.set_container(request, merge_container_id(request.container, id))
    end
  end

  defp carry_container(request, _response), do: request

  defp merge_container_id(current, id) when is_map(current), do: Map.put(current, "id", id)
  defp merge_container_id(_current, id), do: id

  # Runs a turn's calls in content order. After a client-toolset call fails, that
  # toolset's later calls in the turn are not run and get the toolset's halt result
  # (computer-use / browser-use "Batch actions"); other tools keep running.
  defp execute_tools(tool_uses, handlers, on_tool_call) do
    {results, _failed_toolsets} =
      Enum.map_reduce(tool_uses, MapSet.new(), fn tool_use, failed ->
        toolset = tool_use.toolset_name

        if toolset && MapSet.member?(failed, toolset) do
          {Tools.halt_result(tool_use), failed}
        else
          result = run_handler(tool_use, handlers)
          if on_tool_call, do: on_tool_call.(tool_use, result)

          {content, is_error} =
            case result do
              {:ok, value} -> {value, false}
              {:error, reason} -> {reason, true}
            end

          # Only toolsets with a documented halt contract halt; an unknown toolset keeps running.
          failed =
            if is_error and Tools.halt_text(toolset),
              do: MapSet.put(failed, toolset),
              else: failed

          opts = if toolset, do: [toolset_name: toolset], else: []
          {Tools.create_tool_result(tool_use.id, content, is_error, opts), failed}
        end
      end)

    results
  end

  # Dispatch on the (toolset_name, name) pair: a custom tool may share a member's name,
  # and the computer and browser toolsets share names such as "screenshot".
  defp run_handler(%{toolset_name: toolset} = tool_use, handlers) when is_binary(toolset) do
    case Map.get(handlers, toolset) do
      handler when is_function(handler, 2) ->
        safely(fn -> handler.(tool_use.name, tool_use.input) end)

      nil ->
        {:error, "Unknown toolset: #{toolset}"}

      _other ->
        {:error, "Handler for toolset #{toolset} must take (member, input)"}
    end
  end

  defp run_handler(tool_use, handlers) do
    case Map.get(handlers, tool_use.name) do
      handler when is_function(handler, 1) -> safely(fn -> handler.(tool_use.input) end)
      nil -> {:error, "Unknown tool: #{tool_use.name}"}
      _other -> {:error, "Handler for #{tool_use.name} must take (input)"}
    end
  end

  defp safely(fun) do
    fun.()
  catch
    :error, e ->
      {:error, "Tool error: #{Exception.message(Exception.normalize(:error, e, __STACKTRACE__))}"}

    :throw, value ->
      {:error, "Tool threw: #{inspect(value)}"}

    :exit, reason ->
      {:error, "Tool exited: #{inspect(reason)}"}
  end

  defp extract_messages(%Request{messages: messages}), do: messages
end
