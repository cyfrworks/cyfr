# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ExternalServerSseTest do
  @moduledoc """
  Reading a JSON-RPC reply out of an `text/event-stream` response.

  MCP lets a server answer either as JSON or as an event stream, so the
  client has to read both. Two properties of SSE decide what "the answer"
  is, and a line-at-a-time reading gets both wrong:

    * a payload too long for one line is folded across consecutive `data:`
      lines WITHIN one event, joined with newlines — not sent as several
      messages, so keeping only the last line keeps only the last fragment
      of the JSON and throws the rest away;

    * events are separated by a blank line, and a conformant server may
      send progress events before the result — so the answer is the last
      EVENT, not the last `data:` line.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.ExternalServer

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    bypass = Bypass.open()
    {:ok, bypass: bypass, url: "http://127.0.0.1:#{bypass.port}/mcp"}
  end

  defp connect(url, name) do
    pid =
      start_supervised!({ExternalServer, [name: name, url: url, athanor_id: "ath_test"]},
        id: name
      )

    {pid, GenServer.call(pid, :get_tools, 5_000)}
  end

  defp sse(conn, events) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, Enum.join(events, "\r\n\r\n") <> "\r\n\r\n")
  end

  defp result_event(id, tools) do
    payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
    "event: message\r\ndata: " <> payload
  end

  @tool %{"name" => "probe", "description" => "d", "inputSchema" => %{"type" => "object"}}

  test "the result is taken from the last event, not the last line", %{bypass: bypass, url: url} do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      id = Jason.decode!(body)["id"]

      sse(conn, [
        "event: progress\r\ndata: {\"note\":\"working\"}",
        result_event(id, [@tool])
      ])
    end)

    assert {_pid, {:ok, tools}} = connect(url, "sse-progress-peer")
    assert Enum.map(tools, & &1["name"]) == ["probe"]
  end

  test "a payload folded across data: lines is rejoined", %{bypass: bypass, url: url} do
    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      id = Jason.decode!(body)["id"]

      # Pretty-printed JSON: one event whose payload spans many data: lines.
      folded =
        %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => [@tool]}}
        |> Jason.encode!(pretty: true)
        |> String.split("\n")
        |> Enum.map_join("\r\n", &("data: " <> &1))

      sse(conn, ["event: message\r\n" <> folded])
    end)

    assert {_pid, {:ok, tools}} = connect(url, "sse-folded-peer")
    assert Enum.map(tools, & &1["name"]) == ["probe"]
  end

  test "a caller gone mid-call takes its upstream round-trip with it", %{bypass: bypass, url: url} do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      if request["method"] == "tools/call", do: Process.sleep(1_500)
      sse(conn, [result_event(request["id"], [@tool])])
    end)

    assert {pid, {:ok, _tools}} = connect(url, "sse-abandoned-peer")

    caller = spawn(fn -> ExternalServer.call_tool(pid, "probe", %{}) end)

    wait_until(fn -> map_size(:sys.get_state(pid).in_flight) == 1 end, 2_000)
    [task_pid] = Map.keys(:sys.get_state(pid).in_flight)
    task_ref = Process.monitor(task_pid)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}, 2_000
    wait_until(fn -> :sys.get_state(pid).in_flight == %{} end, 2_000)
    Bypass.pass(bypass)
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    unless fun.() do
      if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
      Process.sleep(20)
      wait_until(fun, timeout)
    end
  end
end
