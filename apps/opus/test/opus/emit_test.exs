# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EmitTest do
  @moduledoc """
  A guest's events reach its stream masked of every credential the
  execution was handed, including one split across two streamed deltas;
  what is held back goes out ahead of the next event of any other type;
  an oversized or malformed event is refused without stopping anything.
  """

  use ExUnit.Case, async: false

  alias Opus.Emit

  @secret "sk-live-0123456789abcdef"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    case GenServer.whereis(Opus.RateLimiter) do
      nil -> {:ok, _} = Opus.RateLimiter.start_link([])
      _pid -> :ok
    end

    ctx = Sanctum.TestContext.local()
    stream_id = "exec_emit_#{System.unique_integer([:positive])}"
    Opus.ExecutionEventBuffer.subscribe(stream_id, ctx)
    on_exit(fn -> Opus.ExecutionEventBuffer.unsubscribe(stream_id, ctx) end)

    {:ok, ctx: ctx, stream_id: stream_id}
  end

  defp open(ctx, stream_id, opts \\ []) do
    Emit.open(stream_id, [ctx: ctx, authority: Sanctum.Authority.zero()] ++ opts)
  end

  defp emit(emitter, event), do: Emit.emit(emitter, Jason.encode!(event)) |> Jason.decode!()

  defp received do
    receive do
      {:execution_event, %{type: "emit", data: data}} -> [data | received()]
    after
      200 -> []
    end
  end

  test "a credential split across two text deltas is masked whole, and the tail goes out before stop",
       %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id, secrets: [@secret])
    {head, tail} = String.split_at(@secret, 10)

    assert %{"ok" => true} = emit(emitter, %{"type" => "text.delta", "text" => "key: " <> head})
    emit(emitter, %{"type" => "text.delta", "text" => tail <> " done"})
    assert %{"sequence" => _} = emit(emitter, %{"type" => "stop", "stop_reason" => "end_turn"})

    events = received()
    refute inspect(events) =~ head
    text = events |> Enum.filter(&(&1["type"] == "text.delta")) |> Enum.map_join(& &1["text"])
    assert text == "key: [REDACTED] done"
    assert List.last(events) == %{"type" => "stop", "stop_reason" => "end_turn"}
  end

  test "tool-call arguments are held per index and flushed in order before the next event",
       %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id, secrets: [@secret])

    emit(emitter, %{"type" => "tool_call.delta", "index" => 1, "arguments" => ~s({"b":1})})

    emit(emitter, %{
      "type" => "tool_call.delta",
      "index" => 0,
      "arguments" => ~s({"a":"#{@secret}"})
    })

    emit(emitter, %{"type" => "tool_call.end", "index" => 0})

    events = received()
    refute inspect(events) =~ @secret

    assert Enum.map(events, &{&1["type"], &1["index"]}) ==
             [{"tool_call.delta", 0}, {"tool_call.delta", 1}, {"tool_call.end", 0}]

    assert Enum.at(events, 0)["arguments"] == ~s({"a":"[REDACTED]"})
  end

  test "without credentials nothing is held", %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id)

    assert %{"sequence" => _} = emit(emitter, %{"type" => "text.delta", "text" => "Hel"})
    assert [%{"text" => "Hel"}] = received()
  end

  test "a token dispensed during the run is masked, and stays for the finalize drain",
       %{ctx: ctx, stream_id: stream_id} do
    execution_id = "exec_tracked_#{System.unique_integer([:positive])}"
    :ok = Opus.OAuthTokenTracker.put(execution_id, "ya29.token-value")
    emitter = open(ctx, stream_id, tracked_id: execution_id)

    emit(emitter, %{"type" => "note", "text" => "bearer ya29.token-value"})

    assert [%{"text" => "bearer [REDACTED]"}] = received()
    assert Opus.OAuthTokenTracker.collect(execution_id) == ["ya29.token-value"]
  end

  test "an oversized or malformed event is refused", %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id)
    max = Sanctum.Authority.limits(Sanctum.Authority.zero()).max_request_size

    oversized = Emit.emit(emitter, Jason.encode!(%{"text" => String.duplicate("x", max)}))
    assert %{"error" => %{"type" => "resource_limit"}} = Jason.decode!(oversized)

    assert %{"error" => %{"type" => "invalid_request"}} =
             emitter |> Emit.emit("[1, 2]") |> Jason.decode!()

    assert received() == []
  end

  test "closing an emitter drops what it still held", %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id, secrets: [@secret])
    emit(emitter, %{"type" => "text.delta", "text" => "abc"})
    assert :ok = Emit.close(emitter)
    refute Process.alive?(emitter.held)
    assert received() == []
  end
end
