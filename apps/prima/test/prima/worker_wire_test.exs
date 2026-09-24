# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WorkerWireTest do
  @moduledoc """
  The wire's shape as data: every callback of both behaviours has one
  route and no two callbacks share one; a route reads back to its
  callback; a request body names its callback and reads back only as a
  callback of the behaviour it is read for; answers spell success and
  refusal one way.
  """

  use ExUnit.Case, async: true

  alias Prima.{HostAPI, WorkerAPI, WorkerWire}

  test "the auth header is one lowercase HTTP header name" do
    assert WorkerWire.auth_header() == "x-cyfr-auth"
    assert WorkerWire.auth_header() == String.downcase(WorkerWire.auth_header())
  end

  test "every host callback has one route under /host/v1, and reports go there too" do
    routes = WorkerWire.host_routes()

    assert Enum.sort(Map.keys(routes)) == Enum.sort(HostAPI.callbacks())
    assert Enum.uniq(Map.values(routes)) == Map.values(routes)

    for callback <- HostAPI.callbacks() do
      route = WorkerWire.host_route(callback)
      assert route == "/host/v1/#{callback}"
      assert {:ok, ^callback} = WorkerWire.host_callback(route)
    end

    assert WorkerWire.host_route(:runner_exited) == "/host/v1/runner_exited"
    assert :error = WorkerWire.host_callback("/host/v1/nope")
    assert :error = WorkerWire.host_callback("/worker/v1/kill")
    assert_raise FunctionClauseError, fn -> WorkerWire.host_route(:kill) end
  end

  test "every worker callback has one route under /worker/v1" do
    routes = WorkerWire.worker_routes()

    assert Enum.sort(Map.keys(routes)) == Enum.sort(WorkerAPI.callbacks())
    assert Enum.uniq(Map.values(routes)) == Map.values(routes)

    for callback <- WorkerAPI.callbacks() do
      route = WorkerWire.worker_route(callback)
      assert route == "/worker/v1/#{callback}"
      assert {:ok, ^callback} = WorkerWire.worker_callback(route)
    end

    assert :error = WorkerWire.worker_callback("/host/v1/attach")
    assert_raise FunctionClauseError, fn -> WorkerWire.worker_route(:attach) end
  end

  test "a request body names its callback and reads back for its behaviour only" do
    body = WorkerWire.request_body(:admit_child, %{"reference" => "r"})
    assert body == %{"op" => "admit_child", "args" => %{"reference" => "r"}}

    decoded = body |> Jason.encode!() |> Jason.decode!()

    assert {:ok, :admit_child, %{"reference" => "r"}} =
             WorkerWire.read_request_body(HostAPI, decoded)

    assert {:error, :malformed} = WorkerWire.read_request_body(WorkerAPI, decoded)

    assert {:ok, :kill, %{}} =
             WorkerWire.read_request_body(WorkerAPI, %{"op" => "kill", "args" => %{}})

    for malformed <- [
          %{"op" => "nope", "args" => %{}},
          %{"op" => "attach", "args" => []},
          %{"op" => "attach"},
          %{"args" => %{}},
          %{"op" => :attach, "args" => %{}},
          "attach",
          nil
        ] do
      assert {:error, :malformed} = WorkerWire.read_request_body(HostAPI, malformed),
             inspect(malformed)
    end
  end

  test "answers spell success as ok and a refusal by name with its fields" do
    assert WorkerWire.ok(true) == %{"ok" => true}
    assert WorkerWire.ok(%{"a" => 1}) == %{"ok" => %{"a" => 1}}
    assert WorkerWire.error(:lost) == %{"error" => "lost"}

    assert WorkerWire.error(:guest_error, %{"type" => "denied", "message" => "no"}) ==
             %{"error" => "guest_error", "type" => "denied", "message" => "no"}

    assert WorkerWire.error("failed", %{"message" => "m"}) == %{
             "error" => "failed",
             "message" => "m"
           }

    assert WorkerWire.error("failed", %{"error" => "other"}) == %{"error" => "failed"}
  end

  test "a base URL is http or https with a host and nothing after it" do
    assert {:ok, "http://127.0.0.1:4200"} = WorkerWire.base_url("http://127.0.0.1:4200")
    assert {:ok, "https://opus.internal"} = WorkerWire.base_url("https://opus.internal/")
    assert {:ok, "http://[::1]:4300"} = WorkerWire.base_url("http://[::1]:4300")

    for bad <- [
          "opus:4200",
          "ftp://opus:4200",
          "http://",
          "http:///worker",
          "http://opus:4200/worker/v1",
          "http://opus:4200?x=1",
          "http://opus:4200#f",
          "http://user:pw@opus:4200",
          "",
          nil,
          4200
        ] do
      assert :error = WorkerWire.base_url(bad), "#{inspect(bad)} is no base URL"
    end
  end
end
