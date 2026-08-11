# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ProgressTest do
  @moduledoc """
  Progress belongs to a request, not to a connection.

  The design this replaced keyed a buffer on `context.session_id` and expected a
  separate `GET /mcp` stream keyed the same way. Two properties are asserted here
  because both were broken then: a channel reaches exactly the request that owns
  it, and having no listener is never an error.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.Progress
  alias Sanctum.Context

  defp ctx(request_id) do
    %Context{} = base = Sanctum.TestContext.local()
    %Context{base | request_id: request_id}
  end

  defp receive_progress do
    receive do
      {:mcp_progress, notification} -> notification
    after
      200 -> nil
    end
  end

  test "a listener receives progress for its own request" do
    :ok = Progress.listen("req_own", "tok-1")

    Progress.emit(ctx("req_own"), %{"phase" => "compiling"})

    notification = receive_progress()
    assert notification["method"] == "notifications/progress"
    assert notification["params"]["phase"] == "compiling"
  end

  # The client's opt-in token is stamped by the emitter, so a handler reporting
  # progress never has to know how the caller asked for it.
  test "the client's progressToken is echoed on every notification" do
    :ok = Progress.listen("req_token", "opaque-token-42")

    Progress.emit(ctx("req_token"), %{"phase" => "pulling"})

    assert receive_progress()["params"]["progressToken"] == "opaque-token-42"
  end

  # This is the bug that a session-keyed channel could not avoid: two concurrent
  # calls by one caller share a session id, so each received the other's progress.
  test "a request never receives another request's progress" do
    :ok = Progress.listen("req_a", "tok-a")

    Progress.emit(ctx("req_b"), %{"phase" => "not-for-us"})

    refute receive_progress()
  end

  # Progress is a courtesy. A client that did not ask for it, or that hung up,
  # must not turn into a failure in the code doing the actual work.
  test "emitting with no listener is a silent no-op" do
    assert Progress.emit(ctx("req_nobody"), %{"phase" => "unheard"}) == :ok
    refute receive_progress()
  end

  test "a context with no request id cannot address a channel" do
    assert Progress.emit(ctx(nil), %{}) == :ok
  end
end
