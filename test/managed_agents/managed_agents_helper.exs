defmodule Claudio.ManagedAgentsTestSupport do
  @moduledoc false
  import ExUnit.Assertions

  @beta "managed-agents-2026-04-01"

  # ExUnit setup callback: a Bypass server and a client pointed at it.
  def setup_client(_context) do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "fake-token", version: "2023-06-01"},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # The anthropic-beta header split into its flags ([] when absent).
  def betas(conn) do
    conn
    |> Plug.Conn.get_req_header("anthropic-beta")
    |> Enum.flat_map(&String.split(&1, ","))
  end

  # Expects exactly one `method path` request carrying the managed-agents beta. `check` gets
  # the conn, the decoded query (a list of {name, value} pairs, order kept) and the raw body.
  def expect_call(
        bypass,
        method,
        path,
        response \\ %{"ok" => true},
        check \\ fn _, _, _ -> :ok end
      ) do
    Bypass.expect_once(bypass, method, path, fn conn ->
      assert @beta in betas(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      query = conn.query_string |> URI.query_decoder() |> Enum.to_list()
      check.(conn, query, raw)
      json(conn, 200, response)
    end)
  end
end
