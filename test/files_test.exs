defmodule Claudio.FilesTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{
          token: "fake-token",
          version: "2023-06-01",
          beta: ["files-api-2025-04-14"]
        },
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  describe "upload/3" do
    test "sends multipart POST and returns file metadata", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/files", fn conn ->
        # Verify headers and content-type
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["fake-token"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        assert Plug.Conn.get_req_header(conn, "anthropic-beta") == ["files-api-2025-04-14"]

        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        assert String.starts_with?(content_type, "multipart/form-data")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "file_abc123",
            "type" => "file",
            "filename" => "contract.pdf",
            "mime_type" => "application/pdf",
            "size_bytes" => 12,
            "created_at" => "2026-04-30T00:00:00Z"
          })
        )
      end)

      assert {:ok, %{"id" => "file_abc123", "type" => "file"}} =
               Claudio.Files.upload(client, "fake content",
                 content_type: "application/pdf",
                 filename: "contract.pdf"
               )
    end
  end

  describe "list/2" do
    test "returns the list payload", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        assert Plug.Conn.get_req_header(conn, "anthropic-beta") == ["files-api-2025-04-14"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "file_1", "type" => "file"},
              %{"id" => "file_2", "type" => "file"}
            ],
            "first_id" => "file_1",
            "last_id" => "file_2",
            "has_more" => false
          })
        )
      end)

      assert {:ok, %{"data" => [_, _], "has_more" => false}} = Claudio.Files.list(client)
    end
  end

  describe "get/2" do
    test "returns metadata for a file", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/files/file_abc123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "file_abc123",
            "type" => "file",
            "filename" => "contract.pdf",
            "mime_type" => "application/pdf",
            "size_bytes" => 1234,
            "created_at" => "2026-04-30T00:00:00Z",
            "downloadable" => true
          })
        )
      end)

      assert {:ok, %{"id" => "file_abc123", "downloadable" => true}} =
               Claudio.Files.get(client, "file_abc123")
    end

    test "returns APIError on 404", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/files/file_missing", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{
              "type" => "not_found_error",
              "message" => "File not found"
            }
          })
        )
      end)

      assert {:error, %Claudio.APIError{type: :not_found_error, status_code: 404}} =
               Claudio.Files.get(client, "file_missing")
    end
  end

  describe "download/2" do
    test "returns the raw binary body for a non-JSON content type", %{
      client: client,
      bypass: bypass
    } do
      pdf_bytes = "%PDF-1.4\nfake bytes"

      Bypass.expect_once(bypass, "GET", "/files/file_abc123/content", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.resp(200, pdf_bytes)
      end)

      assert {:ok, ^pdf_bytes} = Claudio.Files.download(client, "file_abc123")
    end
  end

  describe "delete/2" do
    test "returns the deletion confirmation body", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/files/file_abc123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "file_abc123",
            "type" => "file_deleted"
          })
        )
      end)

      assert {:ok, %{"id" => "file_abc123", "type" => "file_deleted"}} =
               Claudio.Files.delete(client, "file_abc123")
    end
  end

  describe "list/2 query params" do
    test "passes :limit, :before_id, and :after_id as query string params", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        # Decode_query is the simplest way to assert all params landed on the wire
        params = URI.decode_query(conn.query_string)
        assert params["limit"] == "50"
        assert params["after_id"] == "file_x"
        assert params["before_id"] == "file_y"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"data" => [], "has_more" => false})
        )
      end)

      assert {:ok, %{"data" => []}} =
               Claudio.Files.list(client,
                 limit: 50,
                 after_id: "file_x",
                 before_id: "file_y"
               )
    end
  end
end
