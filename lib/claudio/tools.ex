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

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "What's the weather in San Francisco?")
      |> Request.add_tool(weather_tool)
      |> Request.set_tool_choice(:auto)

      {:ok, response} = Claudio.Messages.create_message(client, request)

      # Extract tool uses
      tool_uses = Claudio.Tools.extract_tool_uses(response)

      # Execute tools and create results
      results = Enum.map(tool_uses, fn tool_use ->
        result = execute_my_tool(tool_use.name, tool_use.input)
        Claudio.Tools.create_tool_result(tool_use.id, result)
      end)

      # Continue conversation with tool results
      request2 = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "What's the weather in San Francisco?")
      |> Request.add_message(:assistant, response.content)
      |> Request.add_message(:user, results)
  """

  @type tool_definition :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:input_schema) => map()
        }

  @type tool_use :: %{
          id: String.t(),
          name: String.t(),
          input: map()
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

      {:ok, response} = Claudio.Messages.create_message(client, request)
      tool_uses = Claudio.Tools.extract_tool_uses(response)

      Enum.each(tool_uses, fn tool_use ->
        IO.inspect(tool_use.name)
        IO.inspect(tool_use.input)
      end)
  """
  @spec extract_tool_uses(map() | struct()) :: list(tool_use())
  def extract_tool_uses(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&is_tool_use?/1)
    |> Enum.map(&normalize_tool_use/1)
  end

  def extract_tool_uses(%{"content" => content}) when is_list(content) do
    content
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
  @spec create_tool_result(String.t(), String.t() | list(), boolean()) :: tool_result()
  def create_tool_result(tool_use_id, result, is_error \\ false)
      when is_binary(tool_use_id) do
    base = %{
      "type" => "tool_result",
      "tool_use_id" => tool_use_id
    }

    content =
      cond do
        is_binary(result) -> result
        is_list(result) -> result
        is_map(result) -> Poison.encode!(result)
        true -> to_string(result)
      end

    base
    |> Map.put("content", content)
    |> maybe_put_error(is_error)
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

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Initial question")
      |> Request.add_message(:assistant, assistant_response.content)
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

  defp normalize_tool_use(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{id: id, name: name, input: input}
  end

  defp normalize_tool_use(%{type: "tool_use", id: id, name: name, input: input}) do
    %{id: id, name: name, input: input}
  end

  defp normalize_tool_use(%{type: :tool_use, id: id, name: name, input: input}) do
    %{id: id, name: name, input: input}
  end

  defp normalize_tool_use(tool_use), do: tool_use

  defp maybe_put_error(map, false), do: map

  defp maybe_put_error(map, true) do
    Map.put(map, "is_error", true)
  end
end
