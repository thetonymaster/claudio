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
      request = Request.new("claude-sonnet-4-5-20250929")
      |> Request.add_message(:user, "What's the weather in SF?")
      |> Request.add_tool(weather_tool)
      |> Request.set_max_tokens(1024)

      # Run the agent loop
      {:ok, response, messages} = Agent.run(client, request, handlers)

      # response is the final Response struct
      # messages is the full conversation history (for continuing later)

  ## Options

    - `:max_turns` — Maximum tool-calling iterations (default: 10)
    - `:on_tool_call` — Optional callback `fn tool_use, result -> :ok end` for logging/observability
  """

  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}
  alias Claudio.Tools

  @type handler :: (map() -> {:ok, String.t()} | {:error, String.t()})
  @type handlers :: %{String.t() => handler()}

  @type run_result ::
          {:ok, Response.t(), [map()]}
          | {:error, :max_turns_exceeded, Response.t(), [map()]}
          | {:error, term()}

  @default_max_turns 10

  @doc """
  Runs the agent loop until the model stops requesting tools or max_turns is reached.

  `max_turns` limits tool-result round-trips, not API calls. With `max_turns: 2`,
  the model is called up to 3 times: the initial call plus 2 tool-result follow-ups.
  If the third call still requests tools, the loop stops with `:max_turns_exceeded`.

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
      {:ok, %Response{stop_reason: :tool_use} = response} when turn + 1 >= max_turns ->
        messages =
          extract_messages(request) ++
            [%{"role" => "assistant", "content" => serialize_content(response.content)}]

        {:error, :max_turns_exceeded, response, messages}

      {:ok, %Response{stop_reason: :tool_use} = response} ->
        tool_uses = Tools.extract_tool_uses(response)
        tool_results = execute_tools(tool_uses, handlers, on_tool_call)

        updated_request =
          request
          |> Request.add_message(:assistant, serialize_content(response.content))
          # tool_results is a list of tool_result maps — add_message accepts lists as content
          |> Request.add_message(:user, tool_results)

        loop(client, updated_request, handlers, max_turns, on_tool_call, turn + 1)

      {:ok, %Response{} = response} ->
        messages =
          extract_messages(request) ++
            [%{"role" => "assistant", "content" => serialize_content(response.content)}]

        {:ok, response, messages}

      {:error, _} = error ->
        error
    end
  end

  defp execute_tools(tool_uses, handlers, on_tool_call) do
    Enum.map(tool_uses, fn tool_use ->
      result =
        case Map.get(handlers, tool_use.name) do
          nil ->
            {:error, "Unknown tool: #{tool_use.name}"}

          handler when is_function(handler, 1) ->
            try do
              handler.(tool_use.input)
            catch
              :error, e -> {:error, "Tool error: #{Exception.message(e)}"}
              :throw, value -> {:error, "Tool threw: #{inspect(value)}"}
              :exit, reason -> {:error, "Tool exited: #{inspect(reason)}"}
            end
        end

      {content, is_error} =
        case result do
          {:ok, value} -> {value, false}
          {:error, reason} -> {reason, true}
        end

      if on_tool_call, do: on_tool_call.(tool_use, result)

      Tools.create_tool_result(tool_use.id, content, is_error)
    end)
  end

  # Serialize Response content blocks (atom keys) back to API format (string keys)
  defp serialize_content(content) when is_list(content) do
    Enum.map(content, &serialize_block/1)
  end

  defp serialize_block(%{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp serialize_block(%{type: :tool_use, id: id, name: name, input: input}) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp serialize_block(%{type: :thinking, thinking: thinking}) do
    %{"type" => "thinking", "thinking" => thinking}
  end

  defp serialize_block(%{type: :mcp_tool_use} = block) do
    %{
      "type" => "mcp_tool_use",
      "id" => block.id,
      "name" => block.name,
      "server_name" => block.server_name,
      "input" => block.input
    }
  end

  defp serialize_block(%{type: :mcp_tool_result} = block) do
    %{
      "type" => "mcp_tool_result",
      "tool_use_id" => block.tool_use_id,
      "server_name" => block.server_name,
      "content" => block.content,
      "is_error" => block.is_error
    }
  end

  # Passthrough for already-serialized or unknown blocks
  defp serialize_block(block), do: block

  defp extract_messages(%Request{messages: messages}), do: messages
end
