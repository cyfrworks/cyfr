# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.ModelWaitTest do
  @moduledoc """
  The loop waits for a run it dispatched, a brain's answer or a hand's
  tool step, until the run ends at the deadline its catalyst's node is
  consented, which the worker service enforces and reports, and keeps no
  clock of its own. The tests tell that apart from
  a loop that stops the waiter itself when the consent runs out: a brain
  consented five seconds that never answers ends its turn by the worker
  service's reported end, past the consent and its grace, with no kill
  asked by the host, where a loop clock stopped the run first with its
  own `:timeout`; that reported end leaves no unreaped note on the
  athanor's slot and its next root is admitted, where the loop's kill was
  noted; a hand's tool step that hangs to its consented deadline ends the
  same way, where the loop's step clock killed it and noted the kill; and a
  turn on a brain consented thirty minutes lasts at least that long, past
  the five its agent is consented.
  """
  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @hand "catalyst:local.files"
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
    # for one answer and whose files hand the test's time for one run: the
    # shipped catalysts, with those limits changed before anything reads
    # them.
    seed = Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    consented = "#{div(@consented_ms, 1000)}s"
    consent_timeout!(seed, "claude", Map.get(tags, :consent, consented))
    consent_timeout!(seed, "files", Map.get(tags, :hand_consent, consented))

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

  test "a brain that never answers ends its turn when the worker service ends its run at the consented deadline",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "hello")
    start_supervised!({ScriptedWorker, ref: @model, script: [:hang]})

    started = System.monotonic_time(:millisecond)
    assert {:failed, {:uncertain, _}} = Task.await(run(ctx, turn), 60_000)
    waited = System.monotonic_time(:millisecond) - started

    # The consent and the worker service's grace past it, with the run's
    # start and its report around them: far under the ten minutes the loop
    # once gave every model call.
    assert waited >= @consented_ms
    assert waited < 6 * @consented_ms

    # The worker service ended the run at its deadline and reported it;
    # the loop asked for no kill.
    assert [_expired] = ScriptedWorker.expired()
    assert ScriptedWorker.kills() == []

    # The turn's own deadline covers the brain's consented time.
    {:ok, failed} = Tape.turn(ctx, turn.id)
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, failed, authority: authority, excerpt?: false)
    assert spec.deadline_ms >= @consented_ms
  end

  test "a run that hangs to its consented deadline leaves no unreaped note on the athanor's slot, and its next root is admitted",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "hello")
    start_supervised!({ScriptedWorker, ref: @model, script: [:hang, reply("hi")]})
    assert {:failed, {:uncertain, _}} = Task.await(run(ctx, turn), 60_000)

    # The exit the worker service reported ended the run, not a kill of
    # the host's: nothing is held against the athanor once the report has
    # landed.
    :ok = ScriptedWorker.await_reports()
    assert ScriptedWorker.kills() == []
    assert Map.get(Prima.Slots.status(Opus.Slots).unreaped, ctx.athanor_id, 0) == 0

    # The athanor's next root is admitted and runs.
    next = accept!(ctx, thread, "again")
    assert :completed = Task.await(run(ctx, next), 30_000)
  end

  test "a hand's tool step that hangs to its consented deadline leaves no unreaped note on the athanor's slot, and its next root is admitted",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "list my files")

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, @hand],
       script: [calls([{"c1", "files", %{"action" => "list", "path" => "data"}}]), :hang]}
    )

    # The hand's outcome is unknown once its run ended without answering:
    # the turn stops on it, its root let go.
    started = System.monotonic_time(:millisecond)
    assert {:paused, :uncertain} = Task.await(run(ctx, turn), 60_000)
    waited = System.monotonic_time(:millisecond) - started

    # The worker service ended the hand's run at its consented deadline
    # and its grace, and reported it; the loop asked for no kill.
    assert waited >= @consented_ms
    assert [hand_run] = ScriptedWorker.expired()
    {:ok, steps} = Tape.steps(ctx, turn)
    assert [%{child_execution_id: ^hand_run}] = Enum.filter(steps, &(&1.kind == "tool"))
    :ok = ScriptedWorker.await_reports()
    assert ScriptedWorker.kills() == []
    assert Map.get(Prima.Slots.status(Opus.Slots).unreaped, ctx.athanor_id, 0) == 0

    # The athanor's next root is admitted and runs, in a thread of its own
    # beside the stopped turn's.
    ScriptedWorker.script([reply("hi")])
    {:ok, other} = Threads.create(Sanctum.Context.actor(ctx))
    next = accept!(ctx, other, "again")
    assert :completed = Task.await(run(ctx, next), 30_000)
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
    assert spec.deadline_ms == 30 * 60_000
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  defp calls(blocks) do
    %{
      "content" =>
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end),
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
    }
  end

  defp consent_timeout!(seed, catalyst, timeout) do
    [path] =
      Path.wildcard(
        Path.join([seed, "components", "catalysts", "local", catalyst, "*", "cyfr-manifest.json"])
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
