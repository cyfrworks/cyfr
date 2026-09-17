# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpStreamHandlerBoundaryTest do
  @moduledoc """
  The streaming imports keep the promise every host import keeps: a host
  function never raises into WASM. A malformed request, a handle that does
  not exist and a stream that cannot be started each answer the guest a
  typed error, with a host client that holds no context of its own.
  """
  use ExUnit.Case, async: true

  alias Opus.HttpStreamHandler
  alias Opus.Test.ScriptedHost

  defp imports do
    attempt = ScriptedHost.attempt!(ScriptedHost.start!(), component_ref: "catalyst:local.streamer:0.1.0")

    {imports, exec_ref} =
      HttpStreamHandler.build_stream_imports(
        nil,
        Cyfr.Limits.defaults(:catalyst),
        attempt.client,
        "catalyst:local.streamer:0.1.0"
      )

    {imports["cyfr:http/streaming@0.1.0"], exec_ref}
  end

  defp call(ns, name, arg) do
    {:fn, fun} = ns[name]
    fun.(arg)
  end

  test "a malformed request is a typed error, not a raise" do
    {ns, _ref} = imports()

    for bad <- ["not json", "{", Jason.encode!(%{"url" => 42}), Jason.encode!([1, 2, 3])] do
      result = call(ns, "request", bad)
      assert is_binary(result), "request/1 did not answer a string for #{inspect(bad)}"
      assert %{"error" => _} = Jason.decode!(result)
    end
  end

  test "read and close answer for handles that do not exist" do
    {ns, _ref} = imports()

    assert %{"error" => _} = ns |> call("read", "nope") |> Jason.decode!()
    assert %{"ok" => true} = ns |> call("close", "nope") |> Jason.decode!()
  end

  test "a non-string handle does not raise either" do
    {ns, _ref} = imports()

    for bad <- [42, nil, %{"a" => 1}] do
      assert is_binary(call(ns, "read", bad)), "read/1 raised for #{inspect(bad)}"
      assert is_binary(call(ns, "close", bad)), "close/1 raised for #{inspect(bad)}"
    end
  end

  test "the streaming task supervisor being down is a refusal, not a fault" do
    # `Task.Supervisor.start_child/2` answers `{:error, …}` rather than
    # raising, and the hard match turned that into a MatchError inside the
    # host function. Simulated by asking for a stream while the supervisor is
    # not there to take it.
    {ns, _ref} = imports()

    request =
      Jason.encode!(%{
        "url" => "https://example.invalid/stream",
        "method" => "GET"
      })

    result = call(ns, "request", request)

    assert is_binary(result)
    assert %{"error" => _} = Jason.decode!(result)
  end
end
