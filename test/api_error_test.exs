defmodule Claudio.APIErrorTest do
  use ExUnit.Case, async: true

  alias Claudio.APIError

  describe "from_response/2" do
    test "parses authentication error with string keys" do
      body = %{
        "type" => "error",
        "error" => %{
          "type" => "authentication_error",
          "message" => "Invalid API key"
        }
      }

      error = APIError.from_response(401, body)

      assert error.type == :authentication_error
      assert error.message == "Invalid API key"
      assert error.status_code == 401
      assert error.raw_body == body
    end

    test "parses invalid request error with atom keys" do
      body = %{
        type: "error",
        error: %{
          type: "invalid_request_error",
          message: "Missing required field"
        }
      }

      error = APIError.from_response(400, body)

      assert error.type == :invalid_request_error
      assert error.message == "Missing required field"
      assert error.status_code == 400
    end

    test "parses rate limit error" do
      body = %{
        "error" => %{
          "type" => "rate_limit_error",
          "message" => "Rate limit exceeded"
        }
      }

      error = APIError.from_response(429, body)

      assert error.type == :rate_limit_error
    end

    test "parses overloaded error" do
      body = %{
        "error" => %{
          "type" => "overloaded_error",
          "message" => "Service overloaded"
        }
      }

      error = APIError.from_response(529, body)

      assert error.type == :overloaded_error
    end

    test "handles missing error field" do
      body = %{"message" => "Something went wrong"}

      error = APIError.from_response(500, body)

      assert error.type == :api_error
      assert error.message == "Unknown error"
    end

    test "handles unknown error types" do
      body = %{
        "error" => %{
          "type" => "unknown_error_type",
          "message" => "Unknown error"
        }
      }

      error = APIError.from_response(500, body)

      assert error.type == "unknown_error_type"
      assert error.message == "Unknown error"
    end

    test "handles streaming error responses with struct body" do
      # Simulate a streaming error response (e.g., Req.Response.Async)
      body = %Req.Response.Async{ref: make_ref(), stream_fun: nil, cancel_fun: nil}

      error = APIError.from_response(400, body)

      assert error.type == :api_error
      assert error.message == "Streaming request failed with status 400"
      assert error.status_code == 400
      assert error.raw_body == nil
    end
  end

  describe "message/1" do
    test "formats error message" do
      error = %APIError{
        type: :authentication_error,
        message: "Invalid API key",
        status_code: 401
      }

      message = APIError.message(error)

      assert message == "[401] authentication_error: Invalid API key"
    end
  end
end
