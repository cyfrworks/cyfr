# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.StreamOrderTest do
  @moduledoc """
  A chat step's stream reaches the thread whole, in order and masked. Every
  `text.delta` the catalyst emits during its `Cyfr.Execution.run_child/5`
  is forwarded to the thread in sequence order, once, before the loop
  lands the step's row — the forwarder is closed only after the call
  returns, so a delta published after that is never forwarded. A
  credential the catalyst was handed that is split across two deltas, with
  a `tool_call.delta` between them, is never forwarded or streamed
  unmasked.

  The loop runs against the real root and a scripted model catalyst whose
  events go through the engine's emit path.
  """

  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedExecution
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag :requires_opus_modules

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @deltas 50

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "stream_order_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source, :execution_impl]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)
    Application.put_env(:cyfr, :execution_impl, ScriptedExecution)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, thread} = Threads.create(ctx)
    :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Tape.topic(ctx, thread.id))
    {:ok, ctx: ctx, thread: thread}
  end

  test "fifty text deltas reach the thread in sequence order, once each, before the step's row",
       %{ctx: ctx, thread: thread} do
    texts = for i <- 1..@deltas, do: "d#{i} "
    answer = Enum.join(texts)

    start_supervised!(
      {ScriptedExecution,
       ref: @model,
       script: [
         {:emit,
          Enum.map(texts, &%{"type" => "text.delta", "text" => &1}) ++
            [%{"type" => "stop", "stop_reason" => "end_turn"}]},
         reply(answer)
       ]}
    )

    turn = accept!(ctx, thread, "@aqua count")

    assert :completed = Task.await(run(ctx, turn), 60_000)
    assert_receive {:thread, _, {:turn_finished}}, 5_000

    events =
      for {:thread, _, event} <- drain(),
          match?({:delta, _}, event) or match?({:message, %{kind: "text", author: "aqua"}}, event),
          do: event

    {deltas, [{:message, row}]} = Enum.split_while(events, &match?({:delta, _}, &1))
    assert row.content == answer

    assert Enum.map(deltas, fn {:delta, delta} -> delta.text end) == texts
    seqs = Enum.map(deltas, fn {:delta, delta} -> delta.seq end)
    assert seqs == Enum.sort(seqs) and seqs == Enum.uniq(seqs)
    assert length(deltas) == @deltas
  end

  test "a credential split across deltas with a tool call between never streams unmasked",
       %{ctx: ctx, thread: thread} do
    secret = "sk-live-0123456789"

    start_supervised!(
      {ScriptedExecution,
       ref: @model,
       secrets: [secret],
       script: [
         {:emit,
          [
            %{"type" => "text.delta", "text" => "your key is sk-li"},
            %{"type" => "tool_call.delta", "index" => 0, "arguments" => "{\"q\":"},
            %{"type" => "text.delta", "text" => "ve-0123456789, keep it"},
            %{"type" => "tool_call.delta", "index" => 0, "arguments" => "1}"},
            %{"type" => "stop", "stop_reason" => "end_turn"}
          ]},
         reply("noted")
       ]}
    )

    turn = accept!(ctx, thread, "@aqua my key")
    assert :completed = Task.await(run(ctx, turn), 60_000)
    assert_receive {:thread, _, {:turn_finished}}, 5_000

    forwarded = for {:thread, _, {:delta, delta}} <- drain(), do: delta.text
    assert Enum.join(forwarded) == "your key is [REDACTED], keep it"
    refute Enum.any?(forwarded, &(&1 =~ secret))

    assert [chat_id] = chat_calls()
    stream = Cyfr.Execution.events_since(chat_id, {0, 0}, ctx.athanor_id)
    emitted = for %{type: "emit", data: data} <- stream, do: data

    assert [
             %{"type" => "text.delta", "text" => "your key is "},
             %{"type" => "tool_call.delta", "arguments" => "{\"q\":"},
             %{"type" => "text.delta", "text" => "[REDACTED], keep it"},
             %{"type" => "tool_call.delta", "arguments" => "1}"},
             %{"type" => "stop"}
           ] = emitted

    refute inspect(stream, limit: :infinity, printable_limit: :infinity) =~ secret
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  defp chat_calls do
    for %{execution_id: id, input: %{"operation" => "chat"}} <- ScriptedExecution.calls(), do: id
  end

  defp drain do
    receive do
      message -> [message | drain()]
    after
      0 -> []
    end
  end
end
