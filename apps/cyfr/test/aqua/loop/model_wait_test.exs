# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.ModelWaitTest do
  @moduledoc """
  The loop waits for a brain's answer as long as the brain's node is
  consented to take over one answer (`Aqua.Loop.Turn.brain_timeout_ms/1`),
  not for a constant of its own: a brain consented five seconds that never
  answers ends its turn after those seconds, where the ten minutes the loop
  once gave every model call would hold the turn past this test's own
  bound; and a turn on a brain consented thirty minutes lasts at least
  that long, past the five its agent is consented.
  """
  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @consented_ms 5_000

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    ctx = person!()
    tree = own_tree!(ctx)
    workers = Application.get_env(:cyfr, :locus_runtime_workers)

    on_exit(fn ->
      File.rm_rf!(tree)

      if workers,
        do: Application.put_env(:cyfr, :locus_runtime_workers, workers),
        else: Application.delete_env(:cyfr, :locus_runtime_workers)
    end)

    # A seed of this test's own, whose brain is consented the test's time
    # for one answer: the shipped catalysts, with that one limit changed
    # before anything reads them.
    seed = Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    consent_timeout!(seed, Map.get(tags, :consent, "#{div(@consented_ms, 1000)}s"))

    # The loop's work stops before its tree is removed and the seed restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread}
  end

  test "a brain that never answers ends its turn at its consented timeout, not at a constant",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "hello")
    start_supervised!({ScriptedWorker, ref: @model, script: [:hang]})

    started = System.monotonic_time(:millisecond)
    assert {:failed, :timeout} = Task.await(run(ctx, turn), 60_000)
    waited = System.monotonic_time(:millisecond) - started

    # The consent, with the run's start and its stop around it: far under
    # the ten minutes the loop once gave every model call.
    assert waited >= @consented_ms
    assert waited < 4 * @consented_ms

    # The wait was the brain's consented time, which the turn's own
    # deadline covers.
    {:ok, failed} = Tape.turn(ctx, turn.id)
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, failed, authority: authority, excerpt?: false)
    assert Aqua.Loop.Turn.brain_timeout_ms(spec) == @consented_ms
    assert spec.deadline_ms >= @consented_ms

    # The run still hanging was stopped with the wait.
    assert killed?(10), "the hung run was not killed: #{inspect(ScriptedWorker.kills())}"
  end

  @tag consent: "30m"
  test "a turn on a brain consented longer than its agent lasts at least one answer of it",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "hello")
    start_supervised!({ScriptedWorker, ref: @model, script: [reply("hi")]})
    assert :completed = Task.await(run(ctx, turn), 30_000)

    {:ok, pinned} = Tape.turn(ctx, turn.id)
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, pinned, authority: authority, excerpt?: false)

    # The agent's own consented time is under the brain's, and the turn
    # takes the brain's: one answer always fits.
    {:ok, own} = Prima.Limits.timeout_ms(Prima.Authority.limits(authority))
    assert own < 30 * 60_000
    assert Aqua.Loop.Turn.brain_timeout_ms(spec) == 30 * 60_000
    assert spec.deadline_ms == 30 * 60_000
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  # The hung run's kill reaches the worker service after the loop's own
  # stop, so it is waited for, bounded.
  defp killed?(0), do: ScriptedWorker.kills() != []

  defp killed?(tries) do
    ScriptedWorker.kills() != [] or (Process.sleep(200) && killed?(tries - 1))
  end

  defp consent_timeout!(seed, timeout) do
    [path] =
      Path.wildcard(
        Path.join([seed, "components", "catalysts", "local", "claude", "*", "cyfr-manifest.json"])
      )

    manifest = path |> File.read!() |> Jason.decode!()
    File.write!(path, Jason.encode!(put_in(manifest, ["caps", "limits", "timeout"], timeout)))
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  # A person minted for the test with their own athanor, signed in
  # through Prism.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, person} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|wait#{n}",
        provider: "github",
        email: "wait#{n}@example.com",
        verified: true,
        name: "Wait"
      })

    %{
      Sanctum.TestContext.local(:prism)
      | user_id: person.id,
        athanor_id: Sanctum.Test.People.athanor!(person).id
    }
  end

  # The athanor's tree under the partition's storage root, which no earlier
  # test may have left behind.
  defp own_tree!(ctx) do
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    refute File.exists?(tree), "#{ctx.athanor_id}'s tree is left from another test"
    tree
  end
end
