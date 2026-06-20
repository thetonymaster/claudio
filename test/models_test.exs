defmodule Claudio.ModelsTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01"},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  describe "list/2" do
    test "returns the model list", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["fake-token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{
                "id" => "claude-opus-4-8",
                "type" => "model",
                "display_name" => "Claude Opus 4.8",
                "created_at" => "2026-01-01T00:00:00Z"
              }
            ],
            "first_id" => "claude-opus-4-8",
            "last_id" => "claude-opus-4-8",
            "has_more" => false
          })
        )
      end)

      assert {:ok, %{"data" => [%{"id" => "claude-opus-4-8"}]}} =
               Claudio.Models.list(client)
    end

    test "passes :limit, :before_id, and :after_id as query params", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["limit"] == "50"
        assert params["before_id"] == "claude-y"
        assert params["after_id"] == "claude-x"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [], "has_more" => false}))
      end)

      assert {:ok, _} =
               Claudio.Models.list(client, limit: 50, before_id: "claude-y", after_id: "claude-x")
    end

    test "maps non-200 responses to Claudio.APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          401,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
          })
        )
      end)

      assert {:error, %Claudio.APIError{status_code: 401, type: :authentication_error}} =
               Claudio.Models.list(client)
    end
  end

  describe "get/2" do
    test "returns a single model", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models/claude-opus-4-8", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "claude-opus-4-8",
            "type" => "model",
            "display_name" => "Claude Opus 4.8",
            "created_at" => "2026-01-01T00:00:00Z"
          })
        )
      end)

      assert {:ok, %{"id" => "claude-opus-4-8", "type" => "model"}} =
               Claudio.Models.get(client, "claude-opus-4-8")
    end

    test "maps a 404 to Claudio.APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/models/nope", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{"type" => "not_found_error", "message" => "model not found"}
          })
        )
      end)

      assert {:error, %Claudio.APIError{status_code: 404, type: :not_found_error}} =
               Claudio.Models.get(client, "nope")
    end
  end
end
