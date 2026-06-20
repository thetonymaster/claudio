defmodule Claudio.SkillsTest do
  use ExUnit.Case, async: true

  alias Claudio.Skills

  @beta "skills-2025-10-02"

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01"},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp assert_beta(conn) do
    assert Plug.Conn.get_req_header(conn, "anthropic-beta") == [@beta]
    conn
  end

  describe "reads and management" do
    test "list passes limit/source and attaches the skills beta", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/skills", fn conn ->
        conn = assert_beta(conn)
        params = URI.decode_query(conn.query_string)
        assert params["limit"] == "50"
        assert params["source"] == "custom"
        json(conn, 200, %{"data" => [], "has_more" => false, "next_page" => nil})
      end)

      assert {:ok, %{"data" => []}} = Skills.list(client, limit: 50, source: "custom")
    end

    test "get fetches a single skill", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/skills/skill_1", fn conn ->
        conn = assert_beta(conn)
        json(conn, 200, %{"id" => "skill_1", "type" => "skill", "display_title" => "My Skill"})
      end)

      assert {:ok, %{"id" => "skill_1", "type" => "skill"}} = Skills.get(client, "skill_1")
    end

    test "delete issues a DELETE", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/skills/skill_1", fn conn ->
        conn = assert_beta(conn)
        json(conn, 200, %{"id" => "skill_1", "type" => "skill_deleted"})
      end)

      assert {:ok, %{"type" => "skill_deleted"}} = Skills.delete(client, "skill_1")
    end

    test "list_versions / get_version / delete_version hit the version sub-resource", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect(bypass, fn conn ->
        conn = assert_beta(conn)

        case {conn.method, conn.request_path} do
          {"GET", "/skills/skill_1/versions"} -> json(conn, 200, %{"data" => []})
          {"GET", "/skills/skill_1/versions/1759178010641129"} -> json(conn, 200, %{"version" => "1759178010641129"})
          {"DELETE", "/skills/skill_1/versions/1759178010641129"} -> json(conn, 200, %{"deleted" => true})
        end
      end)

      assert {:ok, %{"data" => []}} = Skills.list_versions(client, "skill_1")
      assert {:ok, %{"version" => _}} = Skills.get_version(client, "skill_1", "1759178010641129")
      assert {:ok, %{"deleted" => true}} = Skills.delete_version(client, "skill_1", "1759178010641129")
    end
  end

  describe "multipart create" do
    test "create POSTs multipart/form-data with the beta header", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/skills", fn conn ->
        conn = assert_beta(conn)
        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        assert String.starts_with?(content_type, "multipart/form-data")
        json(conn, 200, %{"id" => "skill_1", "type" => "skill"})
      end)

      form = [file: {"zip-bytes", filename: "skill.zip", content_type: "application/zip"}]
      assert {:ok, %{"id" => "skill_1"}} = Skills.create(client, form)
    end

    test "create_version POSTs multipart to the version sub-resource", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/skills/skill_1/versions", fn conn ->
        conn = assert_beta(conn)
        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        assert String.starts_with?(content_type, "multipart/form-data")
        json(conn, 200, %{"version" => "1759178010641130"})
      end)

      form = [file: {"zip-bytes", filename: "skill.zip", content_type: "application/zip"}]
      assert {:ok, %{"version" => _}} = Skills.create_version(client, "skill_1", form)
    end
  end

  describe "error handling" do
    test "maps a non-2xx to Claudio.APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/skills/nope", fn conn ->
        json(conn, 404, %{
          "type" => "error",
          "error" => %{"type" => "not_found_error", "message" => "skill not found"}
        })
      end)

      assert {:error, %Claudio.APIError{status_code: 404, type: :not_found_error}} =
               Skills.get(client, "nope")
    end
  end
end
