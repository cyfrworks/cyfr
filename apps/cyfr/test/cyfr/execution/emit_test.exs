# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.EmitTest do
  @moduledoc """
  A guest's events reach its stream masked of every credential passed in,
  including one split across two streamed deltas; only a tail that could
  begin a credential is held back, and it goes out when its stream ends or
  when the emitter is flushed, masked with the set as it stands then; every
  stream under one root shares one emit budget; an oversized or malformed
  event is refused without stopping anything.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cyfr.Execution.Emit

  @secret "sk-live-0123456789abcdef"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    stream_id = "exec_emit_#{System.unique_integer([:positive])}"
    Cyfr.Execution.Events.subscribe(stream_id, ctx)
    on_exit(fn -> Cyfr.Execution.Events.unsubscribe(stream_id, ctx) end)

    {:ok, ctx: ctx, stream_id: stream_id}
  end

  defp new(ctx, stream_id, opts \\ []) do
    Emit.new(stream_id, [ctx: ctx, authority: Cyfr.Authority.zero()] ++ opts)
  end

  # Emit each event in turn with `secrets`, answering the last reply and the
  # emitter.
  defp emit(emitter, events, secrets \\ []) do
    events
    |> List.wrap()
    |> Enum.reduce({nil, emitter}, fn event, {_reply, emitter} ->
      {reply, emitter} = Emit.emit(emitter, Jason.encode!(event), secrets)
      {Jason.decode!(reply), emitter}
    end)
  end

  defp received do
    receive do
      {:execution_event, %{type: "emit", data: data}} -> [data | received()]
    after
      200 -> []
    end
  end

  # The consented rate's rows for this caller's athanor — the table an
  # emit must not touch.
  defp rate_windows(ctx) do
    from(w in Arca.Schemas.RateWindow, where: w.athanor_id == ^ctx.athanor_id)
  end

  test "a credential split across two text deltas is masked whole, and the tail goes out before stop",
       %{ctx: ctx, stream_id: stream_id} do
    {head, tail} = String.split_at(@secret, 10)

    {reply, emitter} =
      emit(new(ctx, stream_id), %{"type" => "text.delta", "text" => "key: " <> head}, [@secret])

    assert %{"ok" => true} = reply

    {_reply, emitter} =
      emit(emitter, %{"type" => "text.delta", "text" => tail <> " done"}, [@secret])

    assert {%{"sequence" => _}, _emitter} =
             emit(emitter, %{"type" => "stop", "stop_reason" => "end_turn"}, [@secret])

    events = received()
    refute inspect(events) =~ head
    text = events |> Enum.filter(&(&1["type"] == "text.delta")) |> Enum.map_join(& &1["text"])
    assert text == "key: [REDACTED] done"
    assert List.last(events) == %{"type" => "stop", "stop_reason" => "end_turn"}
  end

  test "a credential split across text deltas stays masked whatever events arrive between them",
       %{ctx: ctx, stream_id: stream_id} do
    {head, tail} = String.split_at(@secret, 10)

    emit(
      new(ctx, stream_id),
      [
        %{"type" => "text.delta", "text" => "key: " <> head},
        %{"type" => "usage", "usage" => %{"input_tokens" => 3}},
        %{"type" => "tool_call.start", "index" => 0, "id" => "c1", "name" => "files"},
        %{"type" => "tool_call.end", "index" => 0},
        %{"type" => "text.delta", "text" => tail <> " done"},
        %{"type" => "stop", "stop_reason" => "end_turn"}
      ],
      [@secret]
    )

    events = received()
    refute inspect(events) =~ head
    refute inspect(events) =~ tail
    text = events |> Enum.filter(&(&1["type"] == "text.delta")) |> Enum.map_join(& &1["text"])
    assert text == "key: [REDACTED] done"
    assert List.last(events)["type"] == "stop"
  end

  test "each call's arguments are held until that call ends, not another's",
       %{ctx: ctx, stream_id: stream_id} do
    {head, tail} = String.split_at(@secret, 10)

    emit(
      new(ctx, stream_id),
      [
        %{"type" => "tool_call.delta", "index" => 0, "arguments" => ~s({"a":") <> head},
        %{"type" => "tool_call.start", "index" => 1, "id" => "c2", "name" => "notes"},
        %{"type" => "tool_call.delta", "index" => 1, "arguments" => ~s({"b":1})},
        %{"type" => "tool_call.end", "index" => 1},
        %{"type" => "tool_call.delta", "index" => 0, "arguments" => tail <> ~s("})},
        %{"type" => "tool_call.end", "index" => 0}
      ],
      [@secret]
    )

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
    assert {%{"sequence" => _}, _emitter} =
             emit(new(ctx, stream_id), %{"type" => "text.delta", "text" => "Hel"})

    assert [%{"text" => "Hel"}] = received()
  end

  test "only a tail that could begin a credential is held back", %{ctx: ctx, stream_id: stream_id} do
    {_reply, emitter} =
      emit(new(ctx, stream_id), %{"type" => "text.delta", "text" => "Hi"}, [@secret])

    assert [%{"text" => "Hi"}] = received()

    {_reply, emitter} =
      emit(emitter, %{"type" => "text.delta", "text" => " there sk-li"}, [@secret])

    assert [%{"text" => " there "}] = received()

    emit(emitter, %{"type" => "text.delta", "text" => "ne"}, [@secret])
    assert [%{"text" => "sk-line"}] = received()
  end

  test "a flush sends every held tail, in stream order, masked with the set it is given",
       %{ctx: ctx, stream_id: stream_id} do
    {_reply, emitter} =
      emit(
        new(ctx, stream_id),
        [
          %{"type" => "tool_call.delta", "index" => 1, "arguments" => ~s({"k":"sk-li)},
          %{"type" => "text.delta", "text" => "the key is sk-li"}
        ],
        [@secret]
      )

    assert [%{"text" => "the key is "}, %{"arguments" => ~s({"k":")}] =
             Enum.sort_by(received(), &Map.has_key?(&1, "arguments"))

    # The tail held back is itself a credential dispensed since.
    emitter = Emit.flush(emitter, [@secret, "sk-li"])

    assert [
             %{"type" => "text.delta", "text" => "[REDACTED]"},
             %{"type" => "tool_call.delta", "index" => 1, "arguments" => "[REDACTED]"}
           ] = received()

    assert emitter.held == %{}
    assert Emit.flush(emitter, [@secret]) == emitter
    assert received() == []
  end

  test "every stream under one root draws on one emit budget", %{ctx: ctx, stream_id: stream_id} do
    root = "exec_root_#{System.unique_integer([:positive])}"
    first = new(ctx, stream_id, budget_id: root)
    second = new(ctx, "exec_sibling_#{System.unique_integer([:positive])}", budget_id: root)

    {_reply, first} = emit(first, List.duplicate(%{"type" => "usage"}, 2999))
    assert {%{"sequence" => _}, second} = emit(second, %{"type" => "usage"})
    assert {%{"error" => %{"type" => "resource_limit"}}, _} = emit(second, %{"type" => "usage"})
    assert {%{"error" => %{"type" => "resource_limit"}}, _} = emit(first, %{"type" => "usage"})
  end

  test "the budget is this member's count, not a row the cell shares", %{
    ctx: ctx,
    stream_id: stream_id
  } do
    root = "exec_root_#{System.unique_integer([:positive])}"
    windows = fn -> Arca.Repo.aggregate(rate_windows(ctx), :count) end
    before = windows.()

    {_reply, _emitter} =
      emit(new(ctx, stream_id, budget_id: root), List.duplicate(%{"type" => "usage"}, 5))

    # A root runs on one member, so its events are counted where they are
    # produced: the delta path takes no round trip to the consented rate's
    # row, and this case's own delta over that table is nothing.
    assert windows.() == before

    # The count is the limiter's, and it is spent: against a cap of five,
    # this member's bucket has nothing left.
    assert {:deny, _retry_after_s} =
             Cyfr.RateLimiter.check({:emit, ctx.athanor_id, root}, 5, :timer.minutes(1))
  end

  test "an oversized or malformed event is refused", %{ctx: ctx, stream_id: stream_id} do
    emitter = new(ctx, stream_id)
    max = Cyfr.Authority.limits(Cyfr.Authority.zero()).max_request_size

    {oversized, ^emitter} =
      Emit.emit(emitter, Jason.encode!(%{"text" => String.duplicate("x", max)}), [])

    assert %{"error" => %{"type" => "resource_limit"}} = Jason.decode!(oversized)

    {malformed, ^emitter} = Emit.emit(emitter, "[1, 2]", [])
    assert %{"error" => %{"type" => "invalid_request"}} = Jason.decode!(malformed)

    assert received() == []
  end
end
