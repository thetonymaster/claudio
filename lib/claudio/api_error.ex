defmodule Claudio.APIError do
  @moduledoc """
  Exception raised when the Anthropic API returns an error response.
  """

  defexception [:type, :message, :status_code, :raw_body]

  @type error_type ::
          :invalid_request_error
          | :authentication_error
          | :permission_error
          | :not_found_error
          | :rate_limit_error
          | :api_error
          | :overloaded_error

  @type t :: %__MODULE__{
          type: error_type() | String.t(),
          message: String.t(),
          status_code: integer(),
          raw_body: map() | String.t() | nil
        }

  @doc """
  Creates a new APIError from an HTTP error response.

  Handles both plain maps (non-streaming responses) and structs like
  `Req.Response.Async` (streaming error responses).
  """
  @spec from_response(integer(), map() | struct() | String.t() | nil) :: t()
  def from_response(status_code, %_{}) do
    # Handle streaming error responses (e.g., Req.Response.Async)
    # These don't have a decoded error body, so we provide a generic error
    %__MODULE__{
      type: :api_error,
      message: "Streaming request failed with status #{status_code}",
      status_code: status_code,
      raw_body: nil
    }
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def from_response(status_code, body) when is_map(body) do
    error_info =
      case body[:error] || body["error"] do
        %{} = info -> info
        _ -> %{}
      end

    type =
      case error_info[:type] || error_info["type"] do
        "invalid_request_error" -> :invalid_request_error
        "authentication_error" -> :authentication_error
        "permission_error" -> :permission_error
        "not_found_error" -> :not_found_error
        "rate_limit_error" -> :rate_limit_error
        "api_error" -> :api_error
        "overloaded_error" -> :overloaded_error
        other when is_binary(other) -> other
        _ -> :api_error
      end

    message = error_info[:message] || error_info["message"] || "Unknown error"

    %__MODULE__{
      type: type,
      message: message,
      status_code: status_code,
      raw_body: body
    }
  end

  # A body that isn't a JSON object — an empty 5xx, a proxy's HTML page, plain text — still
  # becomes an APIError, typed from the HTTP status.
  def from_response(status_code, body) do
    detail =
      case body do
        text when is_binary(text) and text != "" ->
          "a non-JSON body: " <> String.slice(text, 0, 200)

        text when is_binary(text) or is_nil(text) ->
          "an empty body"

        other ->
          "an unexpected body: " <> String.slice(inspect(other), 0, 200)
      end

    %__MODULE__{
      type: type_for_status(status_code),
      message: "HTTP #{status_code} with #{detail}",
      status_code: status_code,
      raw_body: body
    }
  end

  defp type_for_status(401), do: :authentication_error
  defp type_for_status(403), do: :permission_error
  defp type_for_status(404), do: :not_found_error
  defp type_for_status(429), do: :rate_limit_error
  defp type_for_status(529), do: :overloaded_error
  defp type_for_status(_status), do: :api_error

  @impl true
  def message(%__MODULE__{type: type, message: msg, status_code: status}) do
    "[#{status}] #{type}: #{msg}"
  end
end
