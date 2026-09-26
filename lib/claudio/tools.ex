defmodule Claudio.Tools do
  @moduledoc """
  Utilities for working with tools/function calling in the Messages API.

  ## Example

      # Define a tool
      weather_tool = Claudio.Tools.define_tool(
        "get_weather",
        "Get the current weather for a location",
        %{
          "type" => "object",
          "properties" => %{
            "location" => %{
              "type" => "string",
              "description" => "City name or coordinates"
            },
            "unit" => %{
              "type" => "string",
              "enum" => ["celsius", "fahrenheit"],
              "description" => "Temperature unit"
            }
          },
          "required" => ["location"]
        }
      )

      # Use in a request
      alias Claudio.Messages.Request

      request = Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "What's the weather in San Francisco?")
      |> Request.add_tool(weather_tool)
      |> Request.set_tool_choice(:auto)

      {:ok, response} = Claudio.Messages.create(client, request)

      # Extract tool uses
      tool_uses = Claudio.Tools.extract_tool_uses(response)

      # Execute tools and create results
      results = Enum.map(tool_uses, fn tool_use ->
        result = execute_my_tool(tool_use.name, tool_use.input)
        Claudio.Tools.create_tool_result(tool_use.id, result)
      end)

      # Continue conversation with tool results
      request2 = Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "What's the weather in San Francisco?")
      |> Request.add_message(:assistant, Claudio.Messages.Response.to_assistant_content(response))
      |> Request.add_message(:user, results)

  ## Client toolsets

  A call from `Request.add_computer_toolset/2` has a `toolset_name`; answer it with
  `create_tool_result(tool_use.id, result, false, toolset_name: tool_use.toolset_name)`.
  If an action in a batch fails, answer the rest with `halt_result/1`.
  """

  @type tool_definition :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:input_schema) => map()
        }

  @type tool_use :: %{
          id: String.t(),
          name: String.t(),
          input: map(),
          toolset_name: String.t() | nil,
          caller: map() | nil
        }

  @type tool_result :: %{
          type: String.t(),
          tool_use_id: String.t(),
          content: String.t() | list()
        }

  @doc """
  Defines a tool with a name, description, and JSON schema for input validation.

  ## Parameters

  - `name` - Unique identifier for the tool
  - `description` - Human-readable description of what the tool does
  - `input_schema` - JSON Schema object defining the tool's input parameters

  ## Example

      Claudio.Tools.define_tool(
        "calculator",
        "Performs basic arithmetic operations",
        %{
          "type" => "object",
          "properties" => %{
            "operation" => %{
              "type" => "string",
              "enum" => ["add", "subtract", "multiply", "divide"]
            },
            "a" => %{"type" => "number"},
            "b" => %{"type" => "number"}
          },
          "required" => ["operation", "a", "b"]
        }
      )
  """
  @spec define_tool(String.t(), String.t(), map()) :: tool_definition()
  def define_tool(name, description, input_schema)
      when is_binary(name) and is_binary(description) and is_map(input_schema) do
    %{
      "name" => name,
      "description" => description,
      "input_schema" => input_schema
    }
  end

  @doc """
  Extracts tool use requests from a response.

  Returns a list of tool use blocks that need to be executed.

  ## Example

      {:ok, response} = Claudio.Messages.create(client, request)
      tool_uses = Claudio.Tools.extract_tool_uses(response)

      Enum.each(tool_uses, fn tool_use ->
        IO.inspect(tool_use.name)
        IO.inspect(tool_use.input)
      end)

  After a server-side fallback, `tool_use` blocks before the last `fallback` block
  came from the model that declined and are skipped (see
  `Claudio.Messages.Response.to_assistant_content/1`).
  """
  @spec extract_tool_uses(map() | struct()) :: list(tool_use())
  def extract_tool_uses(%{content: content}) when is_list(content) do
    content
    |> Claudio.Messages.Response.since_last_fallback()
    |> Enum.filter(&is_tool_use?/1)
    |> Enum.map(&normalize_tool_use/1)
  end

  def extract_tool_uses(%{"content" => content}) when is_list(content) do
    content
    |> Claudio.Messages.Response.since_last_fallback()
    |> Enum.filter(&is_tool_use?/1)
    |> Enum.map(&normalize_tool_use/1)
  end

  def extract_tool_uses(_), do: []

  @doc """
  Creates a tool result message to continue the conversation after executing a tool.

  ## Parameters

  - `tool_use_id` - The ID from the tool_use block
  - `result` - The result of executing the tool (string or structured content)
  - `is_error` - (optional) Whether this represents an error result
  - `opts` — `toolset_name:` echoes the `tool_use`'s `toolset_name` (required for results
    answering a client-toolset member call; the API rejects them without it).

  ## Example

      tool_result = Claudio.Tools.create_tool_result(
        "toolu_123",
        "The weather in San Francisco is 72°F and sunny"
      )

      # Or with structured content
      tool_result = Claudio.Tools.create_tool_result(
        "toolu_123",
        [%{"type" => "text", "text" => "Here's the data..."}]
      )

      # For errors
      error_result = Claudio.Tools.create_tool_result(
        "toolu_123",
        "Failed to fetch weather data",
        true
      )
  """
  @spec create_tool_result(String.t(), String.t() | list() | map(), boolean(), keyword()) ::
          tool_result()
  def create_tool_result(tool_use_id, result, is_error \\ false, opts \\ [])
      when is_binary(tool_use_id) and is_list(opts) do
    opts = Claudio.Options.validate!(opts, [:toolset_name], "Tools.create_tool_result/4")

    base = %{
      "type" => "tool_result",
      "tool_use_id" => tool_use_id
    }

    content = tool_result_content!(result)

    # The API rejects an empty error result (probed 2026-09-26).
    if is_error and content in ["", []] do
      raise ArgumentError,
            "Tools.create_tool_result/4 with is_error: true needs non-empty content; got #{inspect(result)}"
    end

    base
    |> Map.put("content", content)
    |> maybe_put_error(is_error)
    |> maybe_put_toolset(Keyword.get(opts, :toolset_name))
  end

  # Exact texts from the computer-use and browser-use tool docs ("Batch actions").
  @halt_texts %{
    "computer" => "Not executed: an earlier computer action in this turn failed.",
    "browser" => "Not executed: an earlier action in this turn failed."
  }

  @doc """
  The result for a client-toolset action skipped because an earlier action in the same
  turn failed: `is_error: true`, the exact text the toolset contract prescribes, and
  `toolset_name` echoed. Takes a tool use from `extract_tool_uses/1`.
  """
  @spec halt_result(tool_use()) :: tool_result()
  def halt_result(%{id: id, toolset_name: toolset_name} = tool_use) do
    case halt_text(toolset_name) do
      nil -> raise_halt_argument(tool_use)
      text -> create_tool_result(id, text, true, toolset_name: toolset_name)
    end
  end

  def halt_result(other), do: raise_halt_argument(other)

  @doc """
  The halt text a client toolset prescribes for actions skipped after a failure
  (`"computer"`, `"browser"`), or `nil` for any other toolset name.
  """
  @spec halt_text(String.t() | nil) :: String.t() | nil
  def halt_text(toolset_name), do: Map.get(@halt_texts, toolset_name)

  defp raise_halt_argument(value) do
    raise ArgumentError,
          "Tools.halt_result/1 needs a computer or browser toolset tool use; got #{inspect(value)}"
  end

  @doc """
  Checks if a response indicates that tools were used.

  ## Example

      if Claudio.Tools.has_tool_uses?(response) do
        # Handle tool execution
      end
  """
  @spec has_tool_uses?(map() | struct()) :: boolean()
  def has_tool_uses?(response) do
    extract_tool_uses(response) != []
  end

  @doc """
  Creates a complete tool result message for adding to the conversation.

  This is a convenience function that wraps tool results in a message structure.

  ## Example

      tool_results = [
        Claudio.Tools.create_tool_result("toolu_1", "Result 1"),
        Claudio.Tools.create_tool_result("toolu_2", "Result 2")
      ]

      message = Claudio.Tools.create_tool_result_message(tool_results)

      request = Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "Initial question")
      |> Request.add_message(:assistant, Claudio.Messages.Response.to_assistant_content(assistant_response))
      |> Request.add_message(:user, message)
  """
  @spec create_tool_result_message(list(tool_result())) :: list(tool_result())
  def create_tool_result_message(tool_results) when is_list(tool_results) do
    tool_results
  end

  # Private functions

  defp is_tool_use?(%{"type" => "tool_use"}), do: true
  defp is_tool_use?(%{type: "tool_use"}), do: true
  defp is_tool_use?(%{type: :tool_use}), do: true
  defp is_tool_use?(_), do: false

  defp normalize_tool_use(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = b
       ) do
    %{id: id, name: name, input: input, toolset_name: b["toolset_name"], caller: b["caller"]}
  end

  defp normalize_tool_use(%{type: type, id: id, name: name, input: input} = b)
       when type in ["tool_use", :tool_use] do
    %{id: id, name: name, input: input, toolset_name: b[:toolset_name], caller: b[:caller]}
  end

  # A raw block without "input" (e.g. a hand-built or truncated one) still normalizes.
  defp normalize_tool_use(%{"type" => "tool_use", "id" => id, "name" => name} = b) do
    %{id: id, name: name, input: %{}, toolset_name: b["toolset_name"], caller: b["caller"]}
  end

  defp normalize_tool_use(tool_use), do: tool_use

  defp tool_result_content!(result) when is_binary(result), do: result
  defp tool_result_content!(nil), do: ""

  defp tool_result_content!(result) when is_number(result) or is_atom(result),
    do: to_string(result)

  defp tool_result_content!(result) when is_list(result) do
    if Enum.all?(result, &(is_map(&1) and not is_struct(&1))) do
      result
    else
      raise ArgumentError,
            "Tools.create_tool_result/4 list content must be content blocks (maps like " <>
              "%{\"type\" => \"text\", \"text\" => ...}); got #{inspect(result)}"
    end
  end

  defp tool_result_content!(result) when is_map(result) do
    Jason.encode!(result)
  rescue
    _ in [Protocol.UndefinedError, Jason.EncodeError] -> raise_unsendable!(result)
  end

  defp tool_result_content!(result), do: raise_unsendable!(result)

  defp raise_unsendable!(result) do
    raise ArgumentError,
          "Tools.create_tool_result/4: #{inspect(result)} cannot be sent as tool_result content " <>
            "(use a string, a JSON-encodable map, or a list of content blocks)"
  end

  defp maybe_put_toolset(map, nil), do: map
  defp maybe_put_toolset(map, toolset_name), do: Map.put(map, "toolset_name", toolset_name)

  defp maybe_put_error(map, false), do: map

  defp maybe_put_error(map, true) do
    Map.put(map, "is_error", true)
  end
end
