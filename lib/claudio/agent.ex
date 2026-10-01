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

  ## Compaction

  A `stop_reason: :compaction` reply (`Request.request_compaction/2`, or
  `Request.add_compaction/2` with `pause_after_compaction: true`) is continued with
  `Request.apply_compaction/2` — the history becomes the summary block and the on-demand
  `compaction` field is cleared — and the loop calls the model again with no user turn.
  It counts toward `:max_turns`. A failed compaction (`content: nil`) keeps the history.

  ## Options

    - `:max_turns` — Maximum model calls (default: 10)
    - `:on_tool_call` — Optional callback `fn tool_use, result -> :ok end` for logging/observability.
      Not called for client-toolset actions skipped by a batch halt (they never ran).
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
          | {:error, term(), Response.t() | nil, [map()]}

  @default_max_turns 10

  @doc """
  Runs the agent loop until the model stops requesting tools or max_turns is reached.

  `max_turns` caps the number of model calls. With `max_turns: 2` the model is called at
  most twice — the initial call plus one tool-result (or `pause_turn`) follow-up; if the
  second call still requests tools or pauses, the loop stops with `:max_turns_exceeded`.
  To resume a programmatic run from there, read the container from `last_response.container`
  (it is not in `messages`).

  Returns `{:ok, final_response, messages}` on success, where `messages` is the
  full conversation history including all tool calls and results.

  Returns `{:error, :max_turns_exceeded, last_response, messages}` if the loop
  doesn't converge within `max_turns` model calls. When `last_response` stopped on
  `:tool_use`, the last message in `messages` is that assistant turn with its tool calls
  **not yet executed**: get them with `Claudio.Tools.extract_tool_uses(last_response)`,
  add their results as a user turn, and resume.

  Returns `{:error, reason, last_response, messages}` if an API call fails — `messages` is
  the history up to the failed call (tool results already executed included) and
  `last_response` the previous successful response (`nil` on the first call), so the run
  can be resumed.

  Raises `ArgumentError` if a handler returns anything other than `{:ok, content}` or
  `{:error, reason}` — a programming error, reported with the handler's name.
  """
  @spec run(Req.Request.t(), Request.t(), handlers(), keyword()) :: run_result()
  def run(client, %Request{} = request, tool_handlers, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    on_tool_call = Keyword.get(opts, :on_tool_call)

    unless is_integer(max_turns) and max_turns > 0 do
      raise ArgumentError,
            "Claudio.Agent.run/4 :max_turns must be a positive integer; got #{inspect(max_turns)}"
    end

    if request.stream do
      raise ArgumentError,
            "Claudio.Agent.run/4 does not support streaming requests (stream: true); " <>
              "the loop needs complete responses"
    end

    loop(client, request, tool_handlers, max_turns, on_tool_call, 0, nil)
  end

  # --- Private ---

  defp loop(client, request, handlers, max_turns, on_tool_call, turn, last) do
    case Messages.create(client, request) do
      {:ok, %Response{} = response} ->
        cond do
          not continues?(request, response) ->
            {:ok, response, history_with(request, response)}

          # Checked before anything runs: no handler executes past the call budget.
          turn + 1 >= max_turns ->
            {:error, :max_turns_exceeded, response, history_with(request, response)}

          true ->
            next = next_request(request, response, handlers, on_tool_call)
            loop(client, next, handlers, max_turns, on_tool_call, turn + 1, response)
        end

      {:error, reason} ->
        {:error, reason, last, extract_messages(request)}
    end
  end

  defp continues?(request, %Response{stop_reason: reason} = response) do
    reason in [:tool_use, :pause_turn, :compaction] or
      failed_on_demand_compaction?(request, response)
  end

  # An on-demand compaction that produced no summary comes back as a normal stop with
  # empty content (compaction-on-demand docs, "Handle a missing summary").
  defp failed_on_demand_compaction?(%Request{compaction: nil}, _response), do: false
  defp failed_on_demand_compaction?(_request, %Response{stop_reason: :compaction}), do: false
  defp failed_on_demand_compaction?(_request, %Response{content: []}), do: true
  defp failed_on_demand_compaction?(_request, _response), do: false

  defp history_with(request, %Response{content: []}), do: extract_messages(request)

  defp history_with(request, response) do
    extract_messages(request) ++
      [%{"role" => "assistant", "content" => Response.to_assistant_content(response)}]
  end

  defp next_request(request, response, handlers, on_tool_call) do
    cond do
      # No summary: continue without one (the docs' advice) — drop the compaction request
      # so the next call is a normal turn instead of another summarization.
      failed_on_demand_compaction?(request, response) ->
        %{request | compaction: nil}

      response.stop_reason == :tool_use ->
        tool_uses = Tools.extract_tool_uses(response)
        tool_results = execute_tools(tool_uses, handlers, on_tool_call)

        request
        |> carry_container(response)
        |> Request.add_message(:assistant, Response.to_assistant_content(response))
        # tool_results is a list of tool_result maps — add_message accepts lists as content
        |> Request.add_message(:user, tool_results)

      response.stop_reason == :pause_turn ->
        # A server tool (e.g. the advisor) paused a long turn: resend it unchanged so the
        # API continues it. Counts toward max_turns like a tool round trip.
        request
        |> carry_container(response)
        |> Request.add_message(:assistant, Response.to_assistant_content(response))

      response.stop_reason == :compaction ->
        # A compaction summary (on-demand, or threshold with pause_after_compaction) is not
        # the answer: continue from it with no user turn — the model answers the pending
        # request from the summary (probed 2026-09-26). A failed threshold compaction
        # (content: nil) is a no-op on replay, so keep the history and resend it instead.
        request = carry_container(request, response)

        case Response.compaction_block(response) do
          %{content: content} when is_binary(content) ->
            Request.apply_compaction(request, response)

          _failed ->
            Request.add_message(request, :assistant, Response.to_assistant_content(response))
        end
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

  # Keep the caller's key style: an atom :id map gets :id, so the JSON has one "id".
  defp merge_container_id(%{id: _} = current, id) when not is_map_key(current, "id"),
    do: Map.put(current, :id, id)

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

          {content, is_error} = result_content!(tool_use, result)

          # Only toolsets with a documented halt contract halt; an unknown toolset keeps running.
          failed =
            if is_error and Tools.halt_text(toolset),
              do: MapSet.put(failed, toolset),
              else: failed

          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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

  # Content the API accepts in a tool_result: text, JSON-encodable data, or content blocks.
  defp result_content!(tool_use, {:ok, value} = result) do
    if valid_content?(value), do: {value, false}, else: raise_bad_return!(tool_use, result)
  end

  # Error reasons become text the model can read; an empty one is rejected by the API
  # when is_error is true (probed 2026-09-26).
  defp result_content!(tool_use, {:error, reason} = result) do
    cond do
      reason == "" -> raise_bad_return!(tool_use, result)
      is_binary(reason) -> {reason, true}
      is_exception(reason) -> {Exception.message(reason), true}
      true -> {inspect(reason), true}
    end
  end

  defp result_content!(tool_use, other), do: raise_bad_return!(tool_use, other)

  # Mirrors Tools.create_tool_result/4, which encodes maps/structs and raises its own
  # ArgumentError for unencodable ones.
  defp valid_content?(value)
       when is_binary(value) or is_nil(value) or is_number(value) or is_atom(value) or
              is_map(value),
       do: true

  defp valid_content?(value) when is_list(value),
    do: Enum.all?(value, &(is_map(&1) and not is_struct(&1)))

  defp valid_content?(_value), do: false

  # A handler returning anything else is a programming error: fail loudly with the
  # handler's name instead of a CaseClauseError deep in the loop.
  defp raise_bad_return!(tool_use, other) do
    label =
      if tool_use.toolset_name,
        do: "toolset #{inspect(tool_use.toolset_name)}",
        else: "tool #{inspect(tool_use.name)}"

    raise ArgumentError,
          "Claudio.Agent handler for #{label} must return {:ok, content} (a string, a " <>
            "map, or a list of content-block maps) or {:error, reason} (non-empty); " <>
            "got #{inspect(other)}"
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
