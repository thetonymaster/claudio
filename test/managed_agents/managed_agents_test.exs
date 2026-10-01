Code.require_file("support.exs", __DIR__)

defmodule Claudio.ManagedAgentsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.APIError
  alias Claudio.ManagedAgents
  alias Claudio.ManagedAgents.Agents

  setup :setup_client

  # Serves `pages` (a map from the incoming `page` param — nil for the first call — to the
  # response body), asserting `limit` is kept on every call, and counts calls.
  defp serve_pages(bypass, pages) do
    counter = :counters.new(1, [])

    Bypass.expect(bypass, "GET", "/agents", fn conn ->
      :counters.add(counter, 1, 1)
      params = URI.decode_query(conn.query_string)
      assert params["limit"] == "2"

      case Map.fetch!(pages, params["page"]) do
        {:error, status} ->
          json(conn, status, %{
            "type" => "error",
            "error" => %{"type" => "api_error", "message" => "boom"}
          })

        body ->
          json(conn, 200, body)
      end
    end)

    counter
  end

  defp list_fun(client), do: fn opts -> Agents.list(client, opts) end

  test "walks every page, threading next_page", %{client: client, bypass: bypass} do
    serve_pages(bypass, %{
      nil => %{"data" => [%{"id" => "a1"}, %{"id" => "a2"}], "next_page" => "p2"},
      "p2" => %{"data" => [%{"id" => "a3"}, %{"id" => "a4"}], "next_page" => "p3"},
      "p3" => %{"data" => [%{"id" => "a5"}], "next_page" => nil}
    })

    ids = client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.map(& &1["id"])
    assert ids == ["a1", "a2", "a3", "a4", "a5"]
  end

  test "stops when next_page is absent", %{client: client, bypass: bypass} do
    counter =
      serve_pages(bypass, %{
        nil => %{"data" => [%{"id" => "a1"}], "next_page" => "p2"},
        "p2" => %{"data" => [%{"id" => "a2"}]}
      })

    assert client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.count() == 2
    assert :counters.get(counter, 1) == 2
  end

  test "an empty first page yields nothing", %{client: client, bypass: bypass} do
    serve_pages(bypass, %{nil => %{"data" => []}})
    assert client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.to_list() == []
  end

  test "is lazy: take/2 fetches only the pages it needs", %{client: client, bypass: bypass} do
    counter =
      serve_pages(bypass, %{
        nil => %{"data" => [%{"id" => "a1"}, %{"id" => "a2"}], "next_page" => "p2"},
        "p2" => %{"data" => [%{"id" => "a3"}], "next_page" => nil}
      })

    taken = client |> list_fun() |> ManagedAgents.stream(limit: 2) |> Enum.take(2)
    assert length(taken) == 2
    assert :counters.get(counter, 1) == 1
  end

  test "a page: in the initial opts is used for the first fetch", %{
    client: client,
    bypass: bypass
  } do
    serve_pages(bypass, %{"p2" => %{"data" => [%{"id" => "a3"}], "next_page" => nil}})

    ids =
      client
      |> list_fun()
      |> ManagedAgents.stream(limit: 2, page: "p2")
      |> Enum.map(& &1["id"])

    assert ids == ["a3"]
  end

  test "an error on page 2 raises after page 1's items were emitted", %{
    client: client,
    bypass: bypass
  } do
    serve_pages(bypass, %{
      nil => %{"data" => [%{"id" => "a1"}], "next_page" => "p2"},
      "p2" => {:error, 400}
    })

    stream =
      client
      |> list_fun()
      |> ManagedAgents.stream(limit: 2)
      |> Stream.each(&send(self(), {:item, &1["id"]}))

    assert_raise APIError, ~r/boom/, fn -> Enum.to_list(stream) end
    assert_received {:item, "a1"}
  end

  test "a non-exception error raises RuntimeError with the reason" do
    stream = ManagedAgents.stream(fn _opts -> {:error, :nxdomain} end)
    assert_raise RuntimeError, ~r/:nxdomain/, fn -> Enum.to_list(stream) end
  end

  test "a body without a data list raises ArgumentError" do
    stream = ManagedAgents.stream(fn _opts -> {:ok, %{"id" => "agent_1"}} end)
    assert_raise ArgumentError, ~r/stream\/2.*"data"/, fn -> Enum.to_list(stream) end
  end
end
