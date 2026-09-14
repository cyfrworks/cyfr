# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EmitTest do
  @moduledoc """
  A guest's events reach its stream masked of every credential the
  execution was handed, including one split across two streamed deltas;
  only a tail that could begin a credential is held back, and it goes out
  when its stream ends; every stream under one root shares one emit
  budget; an oversized or malformed event is refused without stopping
  anything.
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
    Emit.open(stream_id, [ctx: ctx, authority: Cyfr.Authority.zero()] ++ opts)
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

  test "a credential split across text deltas stays masked whatever events arrive between them",
       %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id, secrets: [@secret])
    {head, tail} = String.split_at(@secret, 10)

    emit(emitter, %{"type" => "text.delta", "text" => "key: " <> head})
    emit(emitter, %{"type" => "usage", "usage" => %{"input_tokens" => 3}})
    emit(emitter, %{"type" => "tool_call.start", "index" => 0, "id" => "c1", "name" => "files"})
    emit(emitter, %{"type" => "tool_call.end", "index" => 0})
    emit(emitter, %{"type" => "text.delta", "text" => tail <> " done"})
    emit(emitter, %{"type" => "stop", "stop_reason" => "end_turn"})

    events = received()
    refute inspect(events) =~ head
    refute inspect(events) =~ tail
    text = events |> Enum.filter(&(&1["type"] == "text.delta")) |> Enum.map_join(& &1["text"])
    assert text == "key: [REDACTED] done"
    assert List.last(events)["type"] == "stop"
  end

  test "each call's arguments are held until that call ends, not another's",
       %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id, secrets: [@secret])
    {head, tail} = String.split_at(@secret, 10)

    emit(emitter, %{"type" => "tool_call.delta", "index" => 0, "arguments" => ~s({"a":") <> head})
    emit(emitter, %{"type" => "tool_call.start", "index" => 1, "id" => "c2", "name" => "notes"})
    emit(emitter, %{"type" => "tool_call.delta", "index" => 1, "arguments" => ~s({"b":1})})
    emit(emitter, %{"type" => "tool_call.end", "index" => 1})
    emit(emitter, %{"type" => "tool_call.delta", "index" => 0, "arguments" => tail <> ~s("})})
    emit(emitter, %{"type" => "tool_call.end", "index" => 0})

    events = received()
    refute inspect(events) =~ head
    refute inspect(events) =~ tail

    arguments = fn index ->
      events
      |> Enum.filter(&(&1["type"] == "tool_call.delta" and &1["index"] == index))
      |> Enum.map_join(& &1["arguments"])
    end

    assert arguments.(0) == ~s({"a":"[REDACTED]"})
    assert arguments.(1) == ~s({"b":1})

    assert events |> Enum.filter(&(&1["type"] == "tool_call.end")) |> Enum.map(& &1["index"]) ==
             [1, 0]

    # A call's held arguments go out ahead of its own end.
    ends_at = Enum.find_index(events, &(&1["type"] == "tool_call.end" and &1["index"] == 0))

    last_delta_at =
      Enum.find_index(
        Enum.reverse(events),
        &(&1["index"] == 0 and &1["type"] == "tool_call.delta")
      )

    assert length(events) - 1 - last_delta_at < ends_at
  end

  test "without credentials nothing is held", %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id)

    assert %{"sequence" => _} = emit(emitter, %{"type" => "text.delta", "text" => "Hel"})
    assert [%{"text" => "Hel"}] = received()
  end

  test "only a tail that could begin a credential is held back", %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id, secrets: [@secret])

    emit(emitter, %{"type" => "text.delta", "text" => "Hi"})
    assert [%{"text" => "Hi"}] = received()

    emit(emitter, %{"type" => "text.delta", "text" => " there sk-li"})
    assert [%{"text" => " there "}] = received()

    emit(emitter, %{"type" => "text.delta", "text" => "ne"})
    assert [%{"text" => "sk-line"}] = received()
  end

  test "every stream under one root draws on one emit budget", %{ctx: ctx, stream_id: stream_id} do
    root = "exec_root_#{System.unique_integer([:positive])}"
    first = open(ctx, stream_id, budget_id: root)
    second = open(ctx, "exec_sibling_#{System.unique_integer([:positive])}", budget_id: root)

    for _ <- 1..2999, do: emit(first, %{"type" => "usage"})
    assert %{"sequence" => _} = emit(second, %{"type" => "usage"})
    assert %{"error" => %{"type" => "resource_limit"}} = emit(second, %{"type" => "usage"})
    assert %{"error" => %{"type" => "resource_limit"}} = emit(first, %{"type" => "usage"})
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
    max = Cyfr.Authority.limits(Cyfr.Authority.zero()).max_request_size

    oversized = Emit.emit(emitter, Jason.encode!(%{"text" => String.duplicate("x", max)}))
    assert %{"error" => %{"type" => "resource_limit"}} = Jason.decode!(oversized)

    assert %{"error" => %{"type" => "invalid_request"}} =
             emitter |> Emit.emit("[1, 2]") |> Jason.decode!()

    assert received() == []
  end

  test "closing an emitter drops what it still held", %{ctx: ctx, stream_id: stream_id} do
    emitter = open(ctx, stream_id, secrets: [@secret])
    emit(emitter, %{"type" => "text.delta", "text" => "sk-li"})
    assert :ok = Emit.close(emitter)
    refute Process.alive?(emitter.held)
    assert received() == []
  end
end
