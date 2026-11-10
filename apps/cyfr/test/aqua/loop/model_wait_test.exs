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
  same way, where the loop's step clock killed it and noted the kill (the
  `:long` test consents its hand past that five-minute clock); and a
  turn on a brain consented thirty minutes lasts at least that long, past
  the five its agent is consented. A brain whose first chat is
  interrupted answers a refusal carrying the session it opened, and the
  next turn's request continues that session. A brain that refuses the
  thread's session as one it no longer holds is asked the same request
  once more without it, in the same turn: the thread forgets the old
  session and keeps the new one, a refusal of that second request ends
  the turn as any refusal does, and a thread forgotten from outside
  meanwhile keeps nothing the turn answers with. A turn forgets a session
  once: a retry that continues a newer session the brain then refuses the
  same way ends the turn, and the next turn recovers. A refusal of that
  type that names a session is off the contract, and forgets and asks
  nothing.
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

  # A clock of the loop's at or under the hand's consented deadline fails
  # this test. One longer than the test's consent, as the five minutes the
  # loop once kept over every tool step, does not: the long test below
  # consents its hand past those five minutes to fail on that one.
  test "a hand's tool step that hangs to its consented deadline leaves no unreaped note on the athanor's slot, and its next root is admitted",
       %{ctx: ctx, thread: thread} do
    hangs_to_its_deadline!(ctx, thread, @consented_ms)
  end

  @consented_long_ms 6 * 60_000
  @tag :long
  @tag hand_consent: "6m"
  @tag timeout: 15 * 60_000
  @tag ownership_timeout: 15 * 60_000
  test "a hand's tool step consented longer than five minutes is waited for to its deadline, with no unreaped note",
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

  test "a brain's first chat interrupted with a session is resumed by the next turn",
       %{ctx: ctx, thread: thread} do
    interrupted = "The session was interrupted mid-turn. The next message resumes it."
    turn = accept!(ctx, thread, "a long job")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         {:refuse,
          %{"type" => "provider_error", "message" => interrupted, "session" => "brain-1"}},
         reply("Resumed.")
       ]}
    )

    # The refusal ends the turn as any refusal does.
    assert {:failed, ^interrupted} = Task.await(run(ctx, turn), 30_000)

    next = accept!(ctx, thread, "go on")
    assert :completed = Task.await(run(ctx, next), 30_000)

    assert [first, second] =
             for(
               %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
               do: params
             )

    refute Map.has_key?(first, "session")
    assert second["session"] == "brain-1"
  end

  test "a retried chat continues the session its refusal named", %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "a long job")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         {:refuse,
          %{"type" => "incomplete_stream", "message" => "ended early", "session" => "brain-1"}},
         reply("Resumed.")
       ]}
    )

    assert :completed = Task.await(run(ctx, turn), 30_000)

    assert [first, retry] =
             for(
               %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
               do: params
             )

    refute Map.has_key?(first, "session")
    assert retry["session"] == "brain-1"
  end

  test "a brain that no longer holds the thread's session answers on a new one, which the thread keeps",
       %{ctx: ctx, thread: thread} do
    actor = Sanctum.Context.actor(ctx)

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         Map.put(reply("Hello."), "session", "brain-1"),
         {:refuse, unknown_session()},
         Map.put(reply("Here again."), "session", "brain-2"),
         reply("Still here.")
       ]}
    )

    assert :completed = Task.await(run(ctx, accept!(ctx, thread, "hello")), 30_000)

    assert {:ok, %{brain_session: "brain-1", brain_generation: generation}} =
             Threads.get(actor, thread.id)

    # The message is answered in its own turn, on the new session.
    turn = accept!(ctx, thread, "are you there?")
    assert :completed = Task.await(run(ctx, turn), 30_000)

    {:ok, steps} = Tape.steps(ctx, turn)
    assert ["error", "ok"] = for(%{kind: "model", outcome: outcome} <- steps, do: outcome)

    assert {:ok, %{brain_session: "brain-2", brain_generation: forgotten}} =
             Threads.get(actor, thread.id)

    assert forgotten == generation + 1

    assert :completed = Task.await(run(ctx, accept!(ctx, thread, "and now?")), 30_000)

    assert [opened, resumed, again, next] = chat_requests()
    refute Map.has_key?(opened, "session")
    assert resumed["session"] == "brain-1"
    assert again == Map.delete(resumed, "session")
    assert next["session"] == "brain-2"
  end

  test "a refusal of the request asked again without the session ends the turn, the session forgotten",
       %{ctx: ctx, thread: thread} do
    actor = Sanctum.Context.actor(ctx)
    %{"message" => gone} = unknown_session()

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         Map.put(reply("Hello."), "session", "brain-1"),
         {:refuse, unknown_session()},
         {:refuse, unknown_session()},
         reply("Back.")
       ]}
    )

    assert :completed = Task.await(run(ctx, accept!(ctx, thread, "hello")), 30_000)
    {:ok, %{brain_generation: generation}} = Threads.get(actor, thread.id)

    assert {:failed, ^gone} =
             Task.await(run(ctx, accept!(ctx, thread, "are you there?")), 30_000)

    assert {:ok, %{brain_session: nil, brain_generation: forgotten}} =
             Threads.get(actor, thread.id)

    assert forgotten == generation + 1

    # The next message names no session: the thread recovered on its own.
    assert :completed = Task.await(run(ctx, accept!(ctx, thread, "again")), 30_000)

    assert [_opened, resumed, again, next] = chat_requests()
    assert resumed["session"] == "brain-1"
    refute Map.has_key?(again, "session")
    refute Map.has_key?(next, "session")
  end

  # The request asked again is refused for a rate limit and names the
  # session it opened; the ordinary retry continues that session, and the
  # brain no longer holds it either. The turn has forgotten a session once,
  # so it ends there, and the next turn forgets the newer one in its turn.
  test "a second session the brain no longer holds in one turn ends it, with one forget",
       %{ctx: ctx, thread: thread} do
    actor = Sanctum.Context.actor(ctx)
    %{"message" => gone} = unknown_session()
    limited = %{"type" => "rate_limited", "message" => "slow down", "session" => "brain-2"}

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         Map.put(reply("Hello."), "session", "brain-1"),
         {:refuse, unknown_session()},
         {:refuse, limited},
         {:refuse, unknown_session()},
         {:refuse, unknown_session()},
         Map.put(reply("Back."), "session", "brain-3")
       ]}
    )

    assert :completed = Task.await(run(ctx, accept!(ctx, thread, "hello")), 30_000)
    {:ok, %{brain_generation: generation}} = Threads.get(actor, thread.id)

    assert {:failed, ^gone} =
             Task.await(run(ctx, accept!(ctx, thread, "are you there?")), 30_000)

    assert [_opened, resumed, fresh, retried] = chat_requests()
    assert resumed["session"] == "brain-1"
    assert fresh == Map.delete(resumed, "session")
    assert retried == Map.put(fresh, "session", "brain-2")

    assert {:ok, %{brain_session: "brain-2", brain_generation: forgotten}} =
             Threads.get(actor, thread.id)

    assert forgotten == generation + 1

    assert :completed = Task.await(run(ctx, accept!(ctx, thread, "again")), 30_000)

    assert [_, _, _, _, named, anew] = chat_requests()
    assert named["session"] == "brain-2"
    refute Map.has_key?(anew, "session")

    assert {:ok, %{brain_session: "brain-3", brain_generation: recovered}} =
             Threads.get(actor, thread.id)

    assert recovered == generation + 2
  end

  # A refusal of that type that names a session is off the contract
  # (`Prima.Model`): the thread's session stays as it is, nothing is asked
  # again, and the turn ends as it does on any refusal.
  for {what, session} <- [{"a session", "still-present"}, {"a null session", nil}] do
    test "a refusal of the thread's session that names #{what} forgets and asks nothing",
         %{ctx: ctx, thread: thread} do
      actor = Sanctum.Context.actor(ctx)
      refusal = Map.put(unknown_session(), "session", unquote(session))
      %{"message" => gone} = refusal

      start_supervised!(
        {ScriptedWorker,
         ref: @model,
         script: [
           Map.put(reply("Hello."), "session", "brain-1"),
           {:refuse, refusal},
           reply("Never asked.")
         ]}
      )

      assert :completed = Task.await(run(ctx, accept!(ctx, thread, "hello")), 30_000)

      assert {:ok, %{brain_session: "brain-1", brain_generation: generation}} =
               Threads.get(actor, thread.id)

      assert {:failed, ^gone} =
               Task.await(run(ctx, accept!(ctx, thread, "are you there?")), 30_000)

      assert [_opened, resumed] = chat_requests()
      assert resumed["session"] == "brain-1"

      assert {:ok, %{brain_session: "brain-1", brain_generation: ^generation}} =
               Threads.get(actor, thread.id)
    end
  end

  # A program home reset while the request naming the session is out moves
  # the thread on: the turn's own forget finds a generation it did not
  # read, and the session its second request opens, perhaps in the home the
  # reset emptied, is not kept.
  test "a thread forgotten while the refused request was out keeps no session the turn opens",
       %{ctx: ctx, thread: thread} do
    actor = Sanctum.Context.actor(ctx)

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         Map.put(reply("Hello."), "session", "brain-1"),
         {:probe, self()},
         {:refuse, unknown_session()},
         Map.put(reply("Here again."), "session", "brain-2")
       ]}
    )

    assert :completed = Task.await(run(ctx, accept!(ctx, thread, "hello")), 30_000)
    {:ok, %{brain_generation: generation}} = Threads.get(actor, thread.id)

    task = run(ctx, accept!(ctx, thread, "are you there?"))
    assert_receive {:scripted_probe, worker, _}, 30_000
    assert {:ok, 1} = Threads.forget_sessions(actor, ["aqua"])
    send(worker, :continue)
    assert :completed = Task.await(task, 30_000)

    assert {:ok, %{brain_session: nil, brain_generation: reset}} = Threads.get(actor, thread.id)
    assert reset == generation + 1
  end

  # A files hand consented `consented_ms` hangs: the worker service ends
  # its run at that deadline and its grace and reports it, and the loop
  # asked for no kill, so nothing is held against the athanor and its next
  # root runs.
  defp hangs_to_its_deadline!(ctx, thread, consented_ms) do
    turn = accept!(ctx, thread, "list my files")

    start_supervised!(
      {ScriptedWorker,
       ref: [@model, @hand],
       script: [calls([{"c1", "files", %{"action" => "list", "path" => "data"}}]), :hang]}
    )

    # The hand's outcome is unknown once its run ended without answering:
    # the turn stops on it, its root let go.
    started = System.monotonic_time(:millisecond)
    assert {:paused, :uncertain} = Task.await(run(ctx, turn), consented_ms + 60_000)
    waited = System.monotonic_time(:millisecond) - started

    assert waited >= consented_ms
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

  # The refusal of a brain that no longer holds the session a request named.
  defp unknown_session,
    do: %{"type" => "unknown_session", "message" => "The brain no longer holds this session."}

  # The chat requests the scripted brain was sent, in order.
  defp chat_requests do
    for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
        do: params
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
