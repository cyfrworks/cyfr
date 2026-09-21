# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.TurnRootTest do
  @moduledoc """
  A turn's logical root: claimed without a guest, with its row, attempt,
  reservation and a `:root` slot on the calling process; paused and
  resumed with the turn, its attempt and its root moving together, the
  slot let go in between and held once while it runs; lost with its lease,
  claimed or resumed; adopted after a takeover.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts
  alias Arca.TurnStorage
  alias Cyfr.Execution.{LeaseWatch, TurnRoot}
  alias Cyfr.Slots
  alias Sanctum.Consent.{Bootstrap}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @slots Cyfr.Execution.Slots

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "turn_root_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)

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

    {:ok, thread} = Arca.ThreadStorage.create(Sanctum.Context.actor(ctx))

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(Sanctum.Context.actor(ctx), thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, ctx: ctx, turn: turn}
  end

  defp roots, do: Slots.status(@slots).root_active

  defp me_holding?,
    do: Enum.any?(Slots.status(@slots).holders, &(&1.pid == inspect(self())))

  defp holders(pid),
    do: Enum.count(Slots.status(@slots).holders, &(&1.pid == inspect(pid)))

  defp registered(execution_id), do: Registry.lookup(Cyfr.Execution.Registry, execution_id)

  defp execution(id), do: Arca.Repo.get!(Arca.Execution, id)

  # A process holding one `:root` slot for `tenant` on the live instance
  # until told to release, linked so a failing test takes it down.
  defp hold_root(tenant) do
    parent = self()

    pid =
      spawn_link(fn ->
        result = Slots.acquire(@slots, tenant, :root, wait_ms: 5_000)
        send(parent, {:held, self(), result})

        with {:ok, ref} <- result do
          receive do
            :release -> Slots.release(@slots, ref)
          end
        end
      end)

    assert_receive {:held, ^pid, result}, 5_000
    {pid, result}
  end

  defp claim!(ctx, turn, opts \\ []) do
    {:ok, claim} =
      TurnRoot.claim(
        ctx,
        @soul,
        [turn_id: turn.id, envelope: %{"task" => "go"}] ++ opts
      )

    {:ok, started} =
      TurnStorage.start(Sanctum.Context.actor(ctx), turn.id, %{
        root_execution_id: claim.execution_id,
        attempt: claim.attempt,
        budget_id: claim.budget_id,
        profile_id: claim.authority.profile_id,
        consent_id: claim.authority.consent_id,
        fence: turn.fence
      })

    {claim, started}
  end

  test "a claim admits the turn root and holds one root slot on the calling process", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)

    row = execution(claim.execution_id)
    assert row.kind == "turn"
    assert row.component_type == "agent"
    assert row.reference =~ "agent:local.aqua"
    assert row.profile_id == claim.authority.profile_id
    assert is_binary(row.activation_digest)
    assert row.current_attempt == claim.attempt
    assert row.turn_id == turn.id

    assert %{fence: 1, state: "running"} =
             ExecutionAttempts.get(Sanctum.Context.actor(ctx), claim.attempt)

    assert %{cap: cap, released_at: nil} =
             Arca.BudgetReservations.lookup(Sanctum.Context.actor(ctx), claim.budget_id)

    assert cap == claim.authority.budget.cap
    assert roots() == before + 1
    assert me_holding?()
    assert Process.alive?(claim.keeper)
    assert started.status == "running"

    # The holder is registered under the execution for a cancel to find
    # (`Cyfr.Execution.Dispatch.stop/2`), with the slot.
    me = self()
    assert [{^me, :running}] = registered(claim.execution_id)

    # No guest ran: the row has no output and the turn holds the slot
    # itself, so the children it dispatches from workers class as `:child`.
    assert is_nil(row.output)

    {:ok, _} =
      TurnStorage.finish(Sanctum.Context.actor(ctx), turn.id, "completed", %{fence: started.fence})

    :ok = TurnRoot.release(ctx, claim.execution_id, claim: claim)
    assert roots() == before
    assert [] = registered(claim.execution_id)
    refute Process.alive?(claim.keeper)
    assert execution(claim.execution_id).status == "completed"
  end

  test "a claim refused at the athanor's cap fails its row with the refusal's sentence", %{
    ctx: ctx,
    turn: turn
  } do
    %{key_max: key_max} = Slots.status(@slots)
    before = roots()

    # Fill the athanor's roots on the live instance; a holder answered
    # `:key_cap` found it full already.
    holders =
      for _ <- 1..key_max,
          {pid, result} = hold_root(ctx.athanor_id),
          match?({:ok, _}, result),
          do: pid

    assert {:error, :key_cap} = Slots.acquire(@slots, ctx.athanor_id, :root, wait_ms: 0)

    assert {:error, {:slot_refused, sentence}} =
             TurnRoot.claim(ctx, @soul, turn_id: turn.id, envelope: %{"task" => "go"})

    assert sentence == "Athanor at maximum concurrent executions. Retry later."

    # The row the claim would have held says so, and nothing is held or
    # registered for it.
    assert [row] = Arca.Repo.all(from(e in Arca.Execution, where: e.turn_id == ^turn.id))
    assert row.status == "failed"
    assert row.error_message == sentence
    assert [] = registered(row.id)
    refute me_holding?()

    Enum.each(holders, &send(&1, :release))
    wait_until(fn -> roots() == before end)
  end

  test "a resume by a process registered already keeps that process's entry", %{
    ctx: ctx,
    turn: turn
  } do
    {claim, started} = claim!(ctx, turn)

    {:ok, _} =
      TurnRoot.pause(ctx, claim.execution_id,
        claim: claim,
        turn_id: turn.id,
        fence: started.fence,
        reason: "approval"
      )

    assert [] = registered(claim.execution_id)

    # A background task registers before it runs what it registered
    # (`execution.run_stream`): the entry is the task's, and the root's
    # release leaves it.
    me = self()
    {:ok, _} = Registry.register(Cyfr.Execution.Registry, claim.execution_id, :running)

    {:ok, resumed} =
      TurnRoot.resume(ctx, claim.execution_id, turn_id: turn.id, fence: started.fence)

    assert [{^me, :running}] = registered(claim.execution_id)
    assert me_holding?()

    :ok = TurnRoot.release(ctx, claim.execution_id, claim: resumed)
    refute me_holding?()
    assert [{^me, :running}] = registered(claim.execution_id)
    Registry.unregister(Cyfr.Execution.Registry, claim.execution_id)
  end

  test "pause lets the slot go with the rows out of running, and resume takes it back first", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)

    assert {:ok, %{turn: paused}} =
             TurnRoot.pause(ctx, claim.execution_id,
               claim: claim,
               turn_id: turn.id,
               fence: started.fence,
               reason: "approval"
             )

    assert paused.status == "paused"
    assert roots() == before
    refute Process.alive?(claim.keeper)
    assert execution(claim.execution_id).status == "paused"
    assert %{state: "paused"} = ExecutionAttempts.get(Sanctum.Context.actor(ctx), claim.attempt)

    # A lapsed lease on a paused attempt is nobody's business: neither the
    # sweeper nor retention touches it.
    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^claim.attempt),
        set: [lease_until: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

    assert [] = Arca.Execution.list_stale_running(DateTime.utc_now())
    :ok = Cyfr.Execution.Sweeper.sweep()
    assert execution(claim.execution_id).status == "paused"
    assert {:ok, []} = Arca.Execution.stale_ids(0, athanor_id: ctx.athanor_id)

    # Resume from a fresh process: the slot is taken there, the rows move,
    # the keeper renews a new lease.
    test_pid = self()

    task =
      Task.async(fn ->
        {:ok, resumed} =
          TurnRoot.resume(ctx, claim.execution_id,
            turn_id: turn.id,
            fence: started.fence
          )

        send(test_pid, {:resumed, resumed, roots()})
        receive do: (:done -> :ok)
        TurnRoot.release(ctx, claim.execution_id, claim: resumed)
      end)

    assert_receive {:resumed, resumed, roots_while}, 5_000
    assert roots_while == before + 1
    assert resumed.turn.status == "running"
    assert execution(claim.execution_id).status == "running"
    attempt = ExecutionAttempts.get(Sanctum.Context.actor(ctx), claim.attempt)
    assert attempt.state == "running"
    assert DateTime.compare(attempt.lease_until, DateTime.utc_now()) == :gt

    send(task.pid, :done)
    Task.await(task)
    assert roots() == before
  end

  describe "a pause whose rows did not move" do
    setup %{ctx: ctx, turn: turn} do
      # A keeper that outlived its claim would exit this process with
      # `{:lease_lost, _}` once the root's lease is no longer renewable.
      Process.flag(:trap_exit, true)
      before = roots()
      {claim, started} = claim!(ctx, turn, tick_ms: 50)
      assert keepers() == [claim.keeper]

      assert {:error, _} =
               TurnRoot.pause(ctx, claim.execution_id,
                 claim: claim,
                 turn_id: turn.id,
                 fence: started.fence + 1,
                 reason: "approval"
               )

      {:ok, before: before, claim: claim, started: started}
    end

    test "keeps the claim's own keeper renewing, and a retried pause stops it", %{
      ctx: ctx,
      turn: turn,
      before: before,
      claim: claim,
      started: started
    } do
      assert keepers() == [claim.keeper]
      assert roots() == before + 1
      assert execution(claim.execution_id).status == "running"

      %{lease_until: seen} = ExecutionAttempts.get(Sanctum.Context.actor(ctx), claim.attempt)

      wait_until(fn ->
        %{lease_until: now} = ExecutionAttempts.get(Sanctum.Context.actor(ctx), claim.attempt)
        DateTime.compare(now, seen) == :gt
      end)

      assert {:ok, %{turn: %{status: "paused"}}} =
               TurnRoot.pause(ctx, claim.execution_id,
                 claim: claim,
                 turn_id: turn.id,
                 fence: started.fence,
                 reason: "approval"
               )

      refute Process.alive?(claim.keeper)
      assert keepers() == []
      assert roots() == before
      refute_receive {:EXIT, _, {:lease_lost, _}}, 300
    end

    test "leaves exactly the claim's keeper for the release to stop", %{
      ctx: ctx,
      turn: turn,
      before: before,
      claim: claim,
      started: started
    } do
      {:ok, _} =
        TurnStorage.finish(Sanctum.Context.actor(ctx), turn.id, "completed", %{
          fence: started.fence
        })

      :ok = TurnRoot.release(ctx, claim.execution_id, claim: claim)

      refute Process.alive?(claim.keeper)
      assert keepers() == []
      assert roots() == before
      refute_receive {:EXIT, _, {:lease_lost, _}}, 300
    end
  end

  # The lease keepers linked to this process.
  defp keepers do
    {:links, links} = Process.info(self(), :links)

    for pid <- links,
        is_pid(pid),
        {:current_stacktrace, frames} <- [Process.info(pid, :current_stacktrace)],
        Enum.any?(frames, &(elem(&1, 0) == LeaseWatch)),
        do: pid
  end

  test "a lost lease exits the holder, and the slots' monitor releases the slot", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    test_pid = self()

    {holder, ref} =
      spawn_monitor(fn ->
        {claim, _started} = claim!(ctx, turn, tick_ms: 50)
        send(test_pid, {:claimed, claim})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, claim}, 10_000
    assert roots() == before + 1

    # The attempt is retired underneath the holder.
    {:ok, _} =
      ExecutionAttempts.close(Sanctum.Context.actor(ctx), claim.attempt, "failed", "error")

    assert_receive {:DOWN, ^ref, :process, ^holder, {:lease_lost, id}}, 5_000
    assert id == claim.execution_id
    Process.sleep(50)
    assert roots() == before
  end

  test "a resumed root that loses its lease exits its holder, and its slot is released", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)

    {:ok, _} =
      TurnRoot.pause(ctx, claim.execution_id,
        claim: claim,
        turn_id: turn.id,
        fence: started.fence,
        reason: "approval"
      )

    test_pid = self()

    {holder, ref} =
      spawn_monitor(fn ->
        {:ok, resumed} =
          TurnRoot.resume(ctx, claim.execution_id,
            turn_id: turn.id,
            fence: started.fence,
            tick_ms: 50
          )

        send(test_pid, {:resumed, resumed})
        Process.sleep(:infinity)
      end)

    assert_receive {:resumed, resumed}, 10_000
    assert roots() == before + 1

    {:ok, _} =
      ExecutionAttempts.close(Sanctum.Context.actor(ctx), resumed.attempt, "failed", "error")

    assert_receive {:DOWN, ^ref, :process, ^holder, {:lease_lost, id}}, 5_000
    assert id == claim.execution_id
    wait_until(fn -> roots() == before end)
    refute Process.alive?(resumed.keeper)
  end

  test "pause and resume, repeated from fresh holders, hold exactly one root slot while running",
       %{ctx: ctx, turn: turn} do
    before = roots()
    active = Slots.status(@slots).active
    {claim, started} = claim!(ctx, turn)
    assert roots() == before + 1

    pause = fn holding ->
      {:ok, %{turn: paused}} =
        TurnRoot.pause(ctx, claim.execution_id,
          claim: holding,
          turn_id: turn.id,
          fence: started.fence,
          reason: "approval"
        )

      paused
    end

    assert pause.(claim).status == "paused"
    assert roots() == before

    for _cycle <- 1..3 do
      test_pid = self()

      holder =
        Task.async(fn ->
          {:ok, resumed} =
            TurnRoot.resume(ctx, claim.execution_id,
              turn_id: turn.id,
              fence: started.fence
            )

          send(test_pid, {:holding, self()})
          receive do: (:pause -> :ok)
          pause.(resumed)
        end)

      assert_receive {:holding, pid}, 10_000
      assert roots() == before + 1
      assert holders(pid) == 1

      # A second resume while the root runs is refused, and gives back the
      # slot it took before asking.
      assert {:error, _} =
               Task.await(
                 Task.async(fn ->
                   TurnRoot.resume(ctx, claim.execution_id,
                     turn_id: turn.id,
                     fence: started.fence
                   )
                 end)
               )

      wait_until(fn -> roots() == before + 1 end)

      send(pid, :pause)
      assert Task.await(holder).status == "paused"
      wait_until(fn -> roots() == before end)
      assert holders(pid) == 0
    end

    assert execution(claim.execution_id).status == "paused"
    wait_until(fn -> Slots.status(@slots).active == active end)
  end

  # ---------------------------------------------------------------------------
  # A cancelled root
  # ---------------------------------------------------------------------------

  describe "a root whose claim is queued for its slot" do
    setup %{ctx: ctx, turn: turn} do
      watch_unreaped!()
      filler = fill_foreground!()
      claimer = claiming!(ctx, turn)

      wait_until(
        fn -> Slots.status(@slots).queued_by_class.root == 1 end,
        10_000,
        "the claim queued for its slot"
      )

      # Admitted before it queued: its row runs, and nothing holds a slot
      # for it or is registered under it.
      assert [%{status: "running"} = root] =
               Arca.Repo.all(from(e in Arca.Execution, where: e.turn_id == ^turn.id))

      assert [] = registered(root.id)
      {:ok, filler: filler, claimer: claimer, root: root}
    end

    test "cancelled, is refused at its grant: the slot goes straight back, and the cancel is not noted",
         %{ctx: ctx, filler: filler, claimer: claimer, root: %{id: id} = root} do
      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
      refute_received {:unreaped_kill, _count, _tenant, ^id}

      # The slot freed next reaches the claim, which reads its row before it
      # answers.
      release_slots!(filler, 1)
      assert_receive {:claimed, ^claimer, {:error, :not_running}}, 10_000
      assert_given_back(filler, claimer)
      assert [] = registered(root.id)
      assert Process.alive?(claimer)
      assert %{status: "cancelled"} = execution(root.id)
      refute_received {:unreaped_kill, _count, _tenant, ^id}
    end

    test "whose row ends before the grant and whose stop comes after it is not noted",
         %{ctx: ctx, filler: filler, claimer: claimer, root: %{id: id} = root} do
      # The cancel, held between its terminal write and its stop: the row is
      # cancelled while the claim waits, and nobody has stopped anything.
      assert {:ok, %{status: :cancelled}} = Cyfr.Execution.Record.cancel(ctx, root.id)

      release_slots!(filler, 1)
      assert_receive {:claimed, ^claimer, {:error, :not_running}}, 10_000

      # The rest of the cancel finds nothing of the root's to stop.
      assert :ok = Cyfr.Execution.Dispatch.stop(root.id, ctx.athanor_id)
      assert Process.alive?(claimer)
      assert_given_back(filler, claimer)
      assert [] = registered(root.id)
      refute_received {:unreaped_kill, _count, _tenant, ^id}
    end
  end

  test "a takeover's successor cancelled while its adoption waits for a slot is refused at the grant",
       %{ctx: ctx, turn: turn} do
    watch_unreaped!()
    {claim, started} = claim!(ctx, turn)
    :ok = TurnRoot.release(ctx, claim.execution_id, claim: claim)
    id = claim.execution_id

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^claim.attempt),
        set: [lease_until: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    :ok = Cyfr.Execution.Sweeper.sweep()

    {:ok, taken} =
      TurnStorage.takeover(Sanctum.Context.actor(ctx), turn.id, %{fence: started.fence})

    assert execution(id).status == "running"

    filler = fill_foreground!()
    test_pid = self()

    adopter =
      spawn(fn ->
        send(test_pid, {:adopted, self(), TurnRoot.adopt(ctx, id, attempt: taken.attempt)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(adopter, :kill) end)
    wait_until(fn -> Slots.status(@slots).queued_by_class.root == 1 end, 10_000)

    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
    release_slots!(filler, 1)
    assert_receive {:adopted, ^adopter, {:error, :not_running}}, 10_000
    assert_given_back(filler, adopter)
    assert [] = registered(id)
    refute_received {:unreaped_kill, _count, _tenant, ^id}
  end

  test "a running root's cancel kills its holder, and is not noted: nothing native runs in it",
       %{ctx: ctx, turn: turn} do
    watch_unreaped!()
    before = roots()
    test_pid = self()

    {holder, ref} =
      spawn_monitor(fn ->
        {claim, _started} = claim!(ctx, turn)
        send(test_pid, {:claimed, claim})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, %{execution_id: id} = claim}, 10_000
    assert [{^holder, :running}] = registered(id)

    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 5_000
    refute_received {:unreaped_kill, _count, _tenant, ^id}

    wait_until(fn -> roots() == before end, 5_000, "the killed holder's slot came back")
    assert execution(claim.execution_id).status == "cancelled"
  end

  # Every unreaped kill noted from here on, forwarded to this process.
  defp watch_unreaped! do
    handler = "turn-root-unreaped-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :execution, :unreaped_kill],
        &__MODULE__.forward_unreaped/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def forward_unreaped(_event, %{unreaped_count: count}, metadata, test),
    do: send(test, {:unreaped_kill, count, metadata.tenant, metadata.execution_id})

  # Every execution slot a root may take (all but the children's reserve),
  # held by one process under no athanor until `release_slots!/2` gives
  # some back or the test ends: a root claimed now queues, and the next
  # slot given back is the first queued root's.
  defp fill_foreground! do
    %{max: max, child_reserve: reserve, active: active} = Slots.status(@slots)

    {:ok, holder} =
      Agent.start_link(fn ->
        for _ <- 1..(max - reserve - active)//1 do
          {:ok, ref} = Slots.acquire(@slots, nil, :root, wait_ms: 0)
          ref
        end
      end)

    on_exit(fn -> if Process.alive?(holder), do: Agent.stop(holder) end)
    assert {:error, :capacity} = Slots.acquire(@slots, nil, :root, wait_ms: 0)
    %{holder: holder, full: Slots.status(@slots).active}
  end

  defp release_slots!(%{holder: holder}, count) do
    Agent.update(holder, fn refs ->
      {released, kept} = Enum.split(refs, count)
      Enum.each(released, &Slots.release(@slots, &1))
      kept
    end)
  end

  # The slot the filler gave back is free again: the claim holds none, and
  # nothing waits for one.
  defp assert_given_back(%{full: full}, claimer) do
    counts = fn ->
      %{active: active, queued: queued} = Slots.status(@slots)
      {active, queued, holders(claimer)}
    end

    wait_until(fn -> counts.() == {full - 1, 0, 0} end, 10_000, "the granted slot came back")
  end

  # A process that claims the turn's root, tells the test what the claim
  # answered, and lives on holding whatever it was given until the test
  # ends.
  defp claiming!(ctx, turn) do
    test_pid = self()

    pid =
      spawn(fn ->
        result = TurnRoot.claim(ctx, @soul, turn_id: turn.id, envelope: %{"task" => "go"})
        send(test_pid, {:claimed, self(), result})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  test "a takeover's successor is adopted with a slot and a keeper of its own", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)
    # The holder lets go without the turn ending: the keeper stops and the
    # slot goes back, and the row is left to lapse.
    :ok = TurnRoot.release(ctx, claim.execution_id, claim: claim)
    assert roots() == before

    lapsed = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^claim.attempt),
        set: [lease_until: lapsed]
      )

    :ok = Cyfr.Execution.Sweeper.sweep()
    assert execution(claim.execution_id).status == "failed"
    assert %{state: "lapsed"} = ExecutionAttempts.get(Sanctum.Context.actor(ctx), claim.attempt)

    {:ok, taken} =
      TurnStorage.takeover(Sanctum.Context.actor(ctx), turn.id, %{fence: started.fence})

    assert taken.attempt != claim.attempt
    assert execution(claim.execution_id).status == "running"

    {:ok, adopted} =
      TurnRoot.adopt(ctx, claim.execution_id, attempt: taken.attempt, tick_ms: 50)

    assert adopted.attempt == taken.attempt
    assert roots() == before + 1
    assert Process.alive?(adopted.keeper)
    Process.sleep(120)
    # The keeper renews the successor's lease, not the predecessor's.
    assert %{state: "running"} = ExecutionAttempts.get(Sanctum.Context.actor(ctx), taken.attempt)
    assert Process.alive?(self())

    {:ok, _} =
      TurnStorage.finish(Sanctum.Context.actor(ctx), turn.id, "uncertain", %{fence: taken.fence})

    :ok = TurnRoot.release(ctx, claim.execution_id, claim: adopted)
    assert roots() == before
    _ = started
  end
end
