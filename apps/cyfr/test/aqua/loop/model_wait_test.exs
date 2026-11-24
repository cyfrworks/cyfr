# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.ModelWaitTest do
  @moduledoc """
  The loop waits for a run it dispatched, a brain's answer or a hand's
  tool step, until the run ends at the budget its catalyst's node is
  consented, which the worker service enforces, and keeps no clock of its
  own. A run still running at its budget is stopped by the worker service
  and closed uncertain, its kill counted against the athanor once: a
  brain consented five seconds that never answers ends its turn on the
  timeout sentence, with no kill asked by the host, and the athanor's
  next root is still admitted; a hand's tool step that hangs to its
  budget pauses its turn uncertain, since what it did is not known, rather
  than hand the model an error it may answer by running it again (the
  `:long` test consents its hand past the five minutes the loop once
  kept over every tool step); and a turn on a brain consented thirty
  minutes lasts at least that long, past
  the five its agent is consented.
  """
  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @hand "catalyst:local.files"
  @consented_ms 5_000

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(Map.take(tags, [:ownership_timeout]))

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

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread}
  end

  test "a brain that never answers is abandoned at its consented time, and its turn fails on the timeout",
       %{ctx: ctx, thread: thread} do
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)
    turn = accept!(ctx, thread, "hello")
    start_supervised!({ScriptedWorker, ref: @model, script: [:hang]})

    started = System.monotonic_time(:millisecond)
    assert {:failed, _timeout} = Task.await(run(ctx, turn), 60_000)
    waited = System.monotonic_time(:millisecond) - started

    # The worker service stopped the run at its consent, with the run's
    # start and its close around it: far under the ten minutes the loop
    # once gave every model call.
    assert waited >= @consented_ms
    assert waited < 3 * @consented_ms
    {:ok, failed} = Tape.turn(ctx, turn.id)
    assert failed.error =~ ~r/^The model could not be reached: Execution timeout after \d+ms$/

    # The run was stopped at its budget, not by its watchdog, and the loop
    # asked for no kill.
    assert ScriptedWorker.expired() == []
    assert ScriptedWorker.kills() == []

    # The turn's own deadline covers the brain's consented time.
    {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    {:ok, spec} = Aqua.Loop.Turn.build(ctx, failed, authority: authority, excerpt?: false)
    assert spec.deadline_ms >= @consented_ms
  end

  test "a brain run abandoned at its budget is counted against the athanor once, and its next root is admitted",
       %{ctx: ctx, thread: thread} do
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)
    turn = accept!(ctx, thread, "hello")
    start_supervised!({ScriptedWorker, ref: @model, script: [:hang, reply("hi")]})
    assert {:failed, _timeout} = Task.await(run(ctx, turn), 60_000)

    # The stopped guest's native work may still run: CYFR notes it on the
    # athanor's slot, as it notes the runtime's abandoned runs.
    :ok = ScriptedWorker.await_reports()
    assert ScriptedWorker.kills() == []
    assert Map.get(Prima.Slots.status(Opus.Slots).unreaped, ctx.athanor_id, 0) == 1

    # One note is under the athanor's cap: its next root is admitted and runs.
    next = accept!(ctx, thread, "again")
    assert :completed = Task.await(run(ctx, next), 30_000)
  end

  # A clock of the loop's at or under the hand's consented deadline fails
  # this test. One longer than the test's consent, as the five minutes the
  # loop once kept over every tool step, does not: the long test below
  # consents its hand past those five minutes to fail on that one.
  test "a hand's tool step that hangs to its budget pauses its turn uncertain, is counted once against the athanor, and its next root is admitted",
       %{ctx: ctx, thread: thread} do
    hangs_to_its_deadline!(ctx, thread, @consented_ms)
  end

  @consented_long_ms 6 * 60_000
  @tag :long
  @tag hand_consent: "6m"
  @tag timeout: 15 * 60_000
  @tag ownership_timeout: 15 * 60_000
  test "a hand's tool step consented longer than five minutes is waited for to its budget",
       %{ctx: ctx, thread: thread} do
    hangs_to_its_deadline!(ctx, thread, @consented_long_ms)
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

  # A files hand consented `consented_ms` hangs: the worker service stops
  # its run at that budget and closes it abandoned. What the hand did is
  # unknown, so the turn pauses uncertain rather than hand the model an
  # error it may answer by running the write again; the stopped run is
  # noted against the athanor, under its cap, so its next root runs.
  defp hangs_to_its_deadline!(ctx, thread, consented_ms) do
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)
    turn = accept!(ctx, thread, "list my files")

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, @hand],
       script: [calls([{"c1", "files", %{"action" => "list", "path" => "data"}}]), :hang]}
    )

    started = System.monotonic_time(:millisecond)
    assert {:paused, :uncertain} = Task.await(run(ctx, turn), consented_ms + 60_000)
    waited = System.monotonic_time(:millisecond) - started

    assert waited >= consented_ms
    assert ScriptedWorker.expired() == []
    {:ok, steps} = Tape.steps(ctx, turn)

    assert [%{outcome: "uncertain", error: error}] =
             Enum.filter(steps, &(&1.kind == "tool"))

    assert error =~ "Execution timeout after"
    :ok = ScriptedWorker.await_reports()
    assert ScriptedWorker.kills() == []
    assert Map.get(Prima.Slots.status(Opus.Slots).unreaped, ctx.athanor_id, 0) == 1

    # The athanor's next root is admitted and runs, in a thread of its own
    # beside the stopped turn's.
    ScriptedWorker.script([reply("hi")])
    {:ok, other} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    next = accept!(ctx, other, "again")
    assert :completed = Task.await(run(ctx, next), 30_000)
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
