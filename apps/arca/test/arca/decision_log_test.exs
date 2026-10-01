# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DecisionLogTest do
  @moduledoc """
  The decision log's storage rules: one row per call id, attributed to the
  actor; an identical repeat is idempotent and a different one a
  conflict; a completion is recorded once, never for a row outside the
  actor's tenant; the tenant readers never answer a row without a tenant,
  and the global readers are the platform admin's.
  """
  use ExUnit.Case, async: false

  alias Arca.DecisionLog
  alias Arca.DecisionLog.AuditFailure
  alias Prima.Decision

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    n = System.unique_integer([:positive])

    {:ok,
     actor: %{Prima.Actor.in_athanor("ath_decisions_#{n}") | user_id: "usr_#{n}"},
     other: %{Prima.Actor.in_athanor("ath_decisions_other_#{n}") | user_id: "usr_other_#{n}"},
     n: n}
  end

  defp admitted(extra \\ []) do
    Decision.new(
      Keyword.merge(
        [
          call_id: "call_#{System.unique_integer([:positive])}",
          request_id: "req_decisions",
          plane: :external,
          tool: "storage",
          action: "read",
          admission: :admitted,
          inserted_at: DateTime.utc_now()
        ],
        extra
      )
    )
  end

  defp refused(extra \\ []) do
    admitted(
      Keyword.merge([admission: :refused, refusal_class: :forbidden, reason: "No."], extra)
    )
  end

  defp admin, do: %{Prima.Actor.system() | platform_admin: true}

  describe "append" do
    test "writes the admission, attributed to the actor", %{actor: actor} do
      decision = admitted()
      assert :ok = DecisionLog.append(actor, decision)

      assert {:ok, stored} = DecisionLog.get(actor, decision.call_id)
      assert stored.athanor_id == actor.athanor_id
      assert stored.user_id == actor.user_id
      assert stored.admission == :admitted
      assert stored.plane == :external
      assert stored.completion == nil
      assert DateTime.compare(stored.inserted_at, decision.inserted_at) == :eq
    end

    test "an identical repeat is idempotent: one row", %{actor: actor} do
      decision = refused()
      assert :ok = DecisionLog.append(actor, decision)
      assert :ok = DecisionLog.append(actor, decision)

      assert {:ok, [only]} = DecisionLog.correlate(actor, decision.request_id)
      assert only.call_id == decision.call_id
      assert only.refusal_class == :forbidden
    end

    test "a different decision under the same call id is a conflict and writes nothing",
         %{actor: actor} do
      decision = admitted()
      assert :ok = DecisionLog.append(actor, decision)

      assert {:error, %AuditFailure{kind: :conflict, stage: :append}} =
               DecisionLog.append(actor, %{
                 decision
                 | admission: :refused,
                   refusal_class: :forbidden
               })

      assert {:ok, %{admission: :admitted}} = DecisionLog.get(actor, decision.call_id)
    end

    test "a refusal before any caller is the host's row: no tenant, no person" do
      decision = refused(refusal_class: :unauthenticated)
      assert :ok = DecisionLog.append(nil, decision)

      assert {:ok, stored} = DecisionLog.get_global(admin(), decision.call_id)
      assert stored.athanor_id == nil
      assert stored.user_id == nil
    end

    test "attribution is the actor's, never the decision's", %{actor: actor, other: other} do
      assert_raise ArgumentError, ~r/athanor_id is the actor's/, fn ->
        DecisionLog.append(actor, admitted(athanor_id: other.athanor_id))
      end

      assert_raise ArgumentError, ~r/user_id is the actor's/, fn ->
        DecisionLog.append(nil, admitted(user_id: "usr_somebody"))
      end
    end

    test "a decision outside the vocabulary is refused before any write" do
      assert_raise ArgumentError, fn ->
        Decision.new(
          call_id: "call_x",
          plane: :sideways,
          admission: :admitted,
          inserted_at: DateTime.utc_now()
        )
      end

      assert_raise ArgumentError, ~r/refusal names its class/, fn ->
        Decision.new(
          call_id: "call_x",
          plane: :external,
          admission: :refused,
          inserted_at: DateTime.utc_now()
        )
      end
    end

    test "the mcp_log projection is written in the same transaction, once", %{actor: actor} do
      decision = admitted()

      projection = %{
        id: decision.call_id,
        user_id: actor.user_id,
        timestamp: decision.inserted_at,
        status: "pending",
        tool: "storage",
        action: "read",
        method: "tools/call",
        request_id: decision.request_id
      }

      assert :ok = DecisionLog.append(actor, decision, mcp_log: projection)
      assert :ok = DecisionLog.append(actor, decision, mcp_log: projection)

      assert {:ok, [log]} =
               Arca.McpLog.list(request_id: decision.request_id, athanor_id: actor.athanor_id)

      assert log.id == decision.call_id
      assert log.athanor_id == actor.athanor_id

      assert :ok =
               DecisionLog.finish(
                 actor,
                 decision.call_id,
                 %{completion: :succeeded, duration_ms: 3},
                 mcp_log: %{status: "success", duration_ms: 3}
               )

      assert {:ok, [%{status: "success", duration_ms: 3}]} =
               Arca.McpLog.list(request_id: decision.request_id, athanor_id: actor.athanor_id)
    end

    test "a projection needs the actor's athanor" do
      assert_raise ArgumentError, ~r/filed under the actor's athanor/, fn ->
        DecisionLog.append(nil, refused(), mcp_log: %{id: "x", user_id: "u", status: "pending"})
      end
    end
  end

  describe "finish" do
    test "records the completion once; an identical repeat is idempotent", %{actor: actor} do
      decision = admitted()
      :ok = DecisionLog.append(actor, decision)
      completion = %{completion: :failed, completion_class: :timeout, duration_ms: 12}

      assert :ok = DecisionLog.finish(actor, decision.call_id, completion)
      assert :ok = DecisionLog.finish(actor, decision.call_id, completion)

      assert {:ok, stored} = DecisionLog.get(actor, decision.call_id)
      assert stored.completion == :failed
      assert stored.completion_class == :timeout
      assert stored.duration_ms == 12
      assert %DateTime{} = stored.completed_at
      # An execution failure never rewrites the admission as a refusal.
      assert stored.admission == :admitted
    end

    test "a different completion under the same call id is a conflict", %{actor: actor} do
      decision = admitted()
      :ok = DecisionLog.append(actor, decision)
      :ok = DecisionLog.finish(actor, decision.call_id, %{completion: :succeeded})

      assert {:error, %AuditFailure{kind: :conflict, stage: :finish}} =
               DecisionLog.finish(actor, decision.call_id, %{completion: :cancelled})

      assert {:ok, %{completion: :succeeded}} = DecisionLog.get(actor, decision.call_id)
    end

    test "no admission is :not_found, and nothing is synthesized", %{actor: actor} do
      assert {:error, %AuditFailure{kind: :not_found, stage: :finish}} =
               DecisionLog.finish(actor, "call_never_admitted", %{completion: :succeeded})

      assert {:error, :not_found} = DecisionLog.get(actor, "call_never_admitted")
    end

    test "a row outside the actor's tenant is :not_found", %{actor: actor, other: other} do
      decision = admitted()
      :ok = DecisionLog.append(actor, decision)

      assert {:error, %AuditFailure{kind: :not_found}} =
               DecisionLog.finish(other, decision.call_id, %{completion: :succeeded})

      assert {:error, %AuditFailure{kind: :not_found}} =
               DecisionLog.finish(nil, decision.call_id, %{completion: :succeeded})

      assert {:ok, %{completion: nil}} = DecisionLog.get(actor, decision.call_id)
    end

    test "the host finishes its own rows, and no tenant reaches them", %{actor: actor} do
      decision = refused()
      :ok = DecisionLog.append(nil, decision)

      assert {:error, %AuditFailure{kind: :not_found}} =
               DecisionLog.finish(actor, decision.call_id, %{completion: :cancelled})

      assert :ok = DecisionLog.finish(nil, decision.call_id, %{completion: :cancelled})
    end

    test "a completion outside the vocabulary raises", %{actor: actor} do
      assert_raise ArgumentError, ~r/success has no class/, fn ->
        DecisionLog.finish(actor, "call_x", %{completion: :succeeded, completion_class: :timeout})
      end

      assert_raise ArgumentError, ~r/failure names its class/, fn ->
        DecisionLog.finish(actor, "call_x", %{completion: :failed})
      end
    end
  end

  describe "tenant readers" do
    test "exclude the rows without a tenant categorically", %{actor: actor} do
      tenant = admitted(request_id: "req_shared")
      host = refused(request_id: "req_shared", refusal_class: :unauthenticated)
      :ok = DecisionLog.append(actor, tenant)
      :ok = DecisionLog.append(nil, host)

      assert {:ok, [only]} = DecisionLog.correlate(actor, "req_shared")
      assert only.call_id == tenant.call_id
      assert {:ok, listed} = DecisionLog.list(actor, request_id: "req_shared")
      assert Enum.map(listed, & &1.call_id) == [tenant.call_id]
      assert {:error, :not_found} = DecisionLog.get(actor, host.call_id)
    end

    test "answer only the actor's tenant", %{actor: actor, other: other} do
      mine = admitted()
      theirs = admitted()
      :ok = DecisionLog.append(actor, mine)
      :ok = DecisionLog.append(other, theirs)

      assert {:error, :not_found} = DecisionLog.get(actor, theirs.call_id)
      assert {:ok, listed} = DecisionLog.list(actor)
      refute theirs.call_id in Enum.map(listed, & &1.call_id)
      assert mine.call_id in Enum.map(listed, & &1.call_id)
    end

    test "filter and order the tenant's list", %{actor: actor} do
      older = refused(inserted_at: ~U[2026-09-01 00:00:00.000000Z])
      newer = admitted(inserted_at: ~U[2026-09-02 00:00:00.000000Z])
      :ok = DecisionLog.append(actor, older)
      :ok = DecisionLog.append(actor, newer)

      assert {:ok, [first, second | _]} = DecisionLog.list(actor)
      assert {first.call_id, second.call_id} == {newer.call_id, older.call_id}
      assert {:ok, [only]} = DecisionLog.list(actor, admission: :refused)
      assert only.call_id == older.call_id
      assert {:ok, [^only]} = DecisionLog.list(actor, refusal_class: :forbidden)
    end

    test "refuse an actor with no tenant before any query" do
      actor = %Prima.Actor{athanor_id: nil}
      assert {:error, :no_athanor} = DecisionLog.get(actor, "call_x")
      assert {:error, :no_athanor} = DecisionLog.list(actor)
      assert {:error, :no_athanor} = DecisionLog.correlate(actor, "req_x")
      assert {:error, :no_athanor} = DecisionLog.get(%{actor | athanor_id: ""}, "call_x")
    end
  end

  describe "global readers" do
    test "are the platform admin's alone", %{actor: actor} do
      decision = refused()
      :ok = DecisionLog.append(nil, decision)

      assert {:error, :forbidden} = DecisionLog.get_global(actor, decision.call_id)
      assert {:error, :forbidden} = DecisionLog.list_global(actor)
      # The server's own actor reads across tenants, and still is no admin.
      assert {:error, :forbidden} = DecisionLog.list_global(Prima.Actor.system())

      assert {:ok, %{call_id: call_id}} = DecisionLog.get_global(admin(), decision.call_id)
      assert call_id == decision.call_id
    end

    test "read every tenant and the host's rows, or one of them", %{actor: actor, other: other} do
      host = refused(request_id: "req_global")
      mine = admitted(request_id: "req_global")
      theirs = admitted(request_id: "req_global")
      :ok = DecisionLog.append(nil, host)
      :ok = DecisionLog.append(actor, mine)
      :ok = DecisionLog.append(other, theirs)

      assert {:ok, all} = DecisionLog.list_global(admin(), request_id: "req_global")

      assert Enum.sort(Enum.map(all, & &1.call_id)) ==
               Enum.sort([host.call_id, mine.call_id, theirs.call_id])

      assert {:ok, [only_host]} =
               DecisionLog.list_global(admin(), request_id: "req_global", athanor_id: :none)

      assert only_host.call_id == host.call_id

      assert {:ok, [only_mine]} =
               DecisionLog.list_global(admin(),
                 request_id: "req_global",
                 athanor_id: actor.athanor_id
               )

      assert only_mine.call_id == mine.call_id
    end
  end

  describe "retention" do
    test "the tenant cleanup deletes one athanor's old rows only", %{actor: actor, other: other} do
      old = admitted(inserted_at: ~U[2020-01-01 00:00:00.000000Z])
      fresh = admitted()
      theirs = admitted(inserted_at: ~U[2020-01-01 00:00:00.000000Z])
      host = refused(inserted_at: ~U[2020-01-01 00:00:00.000000Z])
      for d <- [old, fresh], do: :ok = DecisionLog.append(actor, d)
      :ok = DecisionLog.append(other, theirs)
      :ok = DecisionLog.append(nil, host)

      cutoff = ~U[2021-01-01 00:00:00Z]
      assert {:ok, 1} = DecisionLog.count_before(cutoff, athanor_id: actor.athanor_id)
      assert {:ok, 1} = DecisionLog.delete_before(cutoff, athanor_id: actor.athanor_id)

      assert {:error, :not_found} = DecisionLog.get(actor, old.call_id)
      assert {:ok, _} = DecisionLog.get(actor, fresh.call_id)
      assert {:ok, _} = DecisionLog.get(other, theirs.call_id)
      assert {:ok, _} = DecisionLog.get_global(admin(), host.call_id)
    end

    test "the host purge takes the platform's system actor and only rows without a tenant",
         %{actor: actor} do
      host_old = refused(inserted_at: ~U[2020-01-01 00:00:00.000000Z])
      host_fresh = refused()
      tenant_old = admitted(inserted_at: ~U[2020-01-01 00:00:00.000000Z])
      :ok = DecisionLog.append(nil, host_old)
      :ok = DecisionLog.append(nil, host_fresh)
      :ok = DecisionLog.append(actor, tenant_old)

      cutoff = ~U[2021-01-01 00:00:00Z]
      assert {:error, :forbidden} = DecisionLog.purge_global(actor, cutoff)

      assert {:error, :forbidden} =
               DecisionLog.purge_global(admin() |> Map.put(:system, false), cutoff)

      assert {:error, :forbidden} =
               DecisionLog.purge_global(
                 %{Prima.Actor.system() | athanor_id: actor.athanor_id, scope: :athanor},
                 cutoff
               )

      assert {:ok, purged} = DecisionLog.purge_global(Prima.Actor.system(), cutoff)
      assert purged >= 1
      assert {:error, :not_found} = DecisionLog.get_global(admin(), host_old.call_id)
      assert {:ok, _} = DecisionLog.get_global(admin(), host_fresh.call_id)
      assert {:ok, _} = DecisionLog.get(actor, tenant_old.call_id)
    end

    test "the tenant kind is rostered in days, default 90" do
      assert Arca.Retention.Decisions in Arca.Retention.kinds()
      assert Arca.Retention.Decisions.key() == "decisions_days"
      assert Arca.Retention.Decisions.unit() == :days
      assert Arca.Retention.Decisions.default() == 90
    end
  end
end

defmodule Arca.DecisionLogBudgetTest do
  @moduledoc """
  The 500 ms budget against a writer the database will not let in: a
  separate connection holds the write lock (`BEGIN IMMEDIATE` on SQLite,
  `LOCK TABLE decision_logs IN ACCESS EXCLUSIVE MODE` on PostgreSQL). The
  caller is answered `:timeout` inside the budget and a scheduler
  allowance, nothing is retried, and when the lock goes the call id holds
  at most the one row — a repeat of the same decision is idempotent.

  The writers under the same lock: no more than the node's cap run at
  once and a write past it is refused at once; a caller's death never
  stops its writer, and a writer asked to stop finishes its write first;
  on SQLite a writer killed in its native call frees its slot at its
  exit, and its connection is lent again only once its disconnect has
  finished.

  Committed rows, under ids of their own and deleted after: the lock must
  be held on a connection the writer does not share, which the sandbox's
  single connection cannot be.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.DecisionLog
  alias Arca.DecisionLog.AuditFailure

  setup do
    call_id = "call_budget_#{System.unique_integer([:positive])}"

    # Every process takes a connection of its own, and on SQLite the
    # writers take turns at the write lock, as a deployment's do. The
    # suite's mode is `:manual` once any shared owner has exited, which is
    # what this puts back, with the turns' switch.
    turn = Application.get_env(:arca, :write_turn)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :auto)
    Application.put_env(:arca, :write_turn, true)

    on_exit(fn ->
      Task.async(fn ->
        Arca.Repo.delete_all(from(r in "decision_logs", where: r.call_id == ^call_id))
      end)
      |> Task.await(:infinity)

      Application.put_env(:arca, :write_turn, turn)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, :manual)
    end)

    {:ok, call_id: call_id, actor: Prima.Actor.in_athanor("ath_budget")}
  end

  # Linked, so a failing assertion takes the lock down with the test.
  defp hold_write_lock(parent) do
    spawn_link(fn ->
      case Arca.Repo.adapter() do
        Ecto.Adapters.SQLite3 ->
          Arca.Repo.checkout(
            fn ->
              Arca.Repo.query!("BEGIN IMMEDIATE", [], log: false)
              send(parent, :locked)
              receive do: (:release -> :ok)
              Arca.Repo.query!("ROLLBACK", [], log: false)
            end,
            timeout: :infinity
          )

        _postgres ->
          Arca.Repo.transaction(
            fn ->
              Arca.Repo.query!("LOCK TABLE decision_logs IN ACCESS EXCLUSIVE MODE", [],
                log: false
              )

              send(parent, :locked)
              receive do: (:release -> :ok)
            end,
            timeout: :infinity
          )
      end

      send(parent, :released)
    end)
  end

  # The writers `append/3` started for this test and that are still running:
  # a write that outlived its caller's answer. They are waited out before
  # the test ends, because the ownership switch in `on_exit` checks every
  # connection in, and a connection taken back while its statement steps
  # inside the driver is the VM crash the writer's own bound avoids.
  defp writers(caller) do
    for pid <- Process.list(),
        pid != caller,
        {:dictionary, dict} <- [Process.info(pid, :dictionary)],
        caller in List.wrap(dict[:"$callers"]),
        do: pid
  end

  defp rows(call_id) do
    Task.async(fn ->
      Arca.Repo.aggregate(from(r in "decision_logs", where: r.call_id == ^call_id), :count)
    end)
    |> Task.await(:infinity)
  end

  test "a transaction whose pool deadline is nearly spent takes no lock wait" do
    blocker = hold_write_lock(self())
    assert_receive :locked, 5_000
    started = System.monotonic_time(:millisecond)
    deadline = started + 100

    result =
      Task.async(fn ->
        try do
          Arca.Repo.transaction(fn -> :ok end, timeout: 5_000, pool_deadline: deadline)
        rescue
          e in Arca.Repo.BusyTimeoutError -> {:raised, e}
        end
      end)
      |> Task.await(:infinity)

    elapsed = System.monotonic_time(:millisecond) - started

    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        # Less than the commit slack was left at the lock step, so it
        # raised before any attempt: no lock quantum, no pause, and long
        # before the busy timeout.
        assert {:raised, %Arca.Repo.BusyTimeoutError{}} = result
        assert elapsed < 300, "refused after #{elapsed} ms"

      _postgres ->
        # The option is SQLite's; a transaction that touches no locked
        # table runs as it would.
        assert {:ok, :ok} = result
    end

    send(blocker, :release)
    assert_receive :released, 5_000
  end

  test "a blocked writer is a :timeout within the budget, and the id holds one row at most",
       %{call_id: call_id, actor: actor} do
    decision =
      Prima.Decision.new(
        call_id: call_id,
        plane: :external,
        admission: :admitted,
        tool: "t",
        action: "a",
        inserted_at: DateTime.utc_now()
      )

    blocker = hold_write_lock(self())
    assert_receive :locked, 5_000

    started = System.monotonic_time(:millisecond)

    assert {:error, %AuditFailure{kind: :timeout, stage: :append}} =
             Task.async(fn -> DecisionLog.append(actor, decision) end) |> Task.await(:infinity)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= DecisionLog.budget_ms() - 50
    # The budget and a scheduler allowance.
    assert elapsed < DecisionLog.budget_ms() + 250, "settled after #{elapsed} ms"

    # On SQLite the writer outlived the answer: it is still waiting on the
    # lock, bounded by the driver's lock wait. On PostgreSQL the pool closed
    # its connection at the deadline and it ended with the answer.
    late = for pid <- writers(self()), do: Process.monitor(pid)
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3, do: assert(late != [])

    send(blocker, :release)
    assert_receive :released, 5_000
    for ref <- late, do: assert_receive({:DOWN, ^ref, :process, _, _}, 30_000)

    # No late duplicate: on SQLite the late write lands as the one row once
    # the lock goes; on PostgreSQL the pool closed the writer's connection at
    # the deadline and its transaction rolled back. A repeat of the same
    # decision is idempotent either way: never two.
    assert rows(call_id) <= 1

    assert :ok =
             Task.async(fn -> DecisionLog.append(actor, decision) end) |> Task.await(:infinity)

    assert rows(call_id) == 1
  end

  test "a write past the writer cap is refused at once, and an overload runs no more than the cap",
       %{call_id: call_id, actor: actor} do
    ids = for i <- 1..40, do: "#{call_id}_#{i}"
    on_exit(fn -> delete_rows(ids) end)
    blocker = hold_write_lock(self())
    assert_receive :locked, 5_000
    sampler = spawn_link(fn -> sampling([]) end)

    answers =
      ids
      |> Enum.map(fn id ->
        Task.async(fn ->
          started = System.monotonic_time(:millisecond)
          answer = DecisionLog.append(actor, decision(id))
          {answer, System.monotonic_time(:millisecond) - started}
        end)
      end)
      |> Enum.map(&Task.await(&1, :infinity))

    refused = for {{:error, %AuditFailure{kind: :capacity}}, ms} <- answers, do: ms
    waited = for {{:error, %AuditFailure{kind: :timeout}}, _ms} <- answers, do: :timeout
    # Under load the store can fail an admitted writer outright (on
    # PostgreSQL a `Postgrex.Error`) before its caller's budget runs out,
    # and that caller is answered `:unavailable` instead of `:timeout`.
    unavailable = for {{:error, %AuditFailure{kind: :unavailable}}, _ms} <- answers, do: :failed

    # Every writer past the cap was refused, each answered before the
    # budget an admitted writer's caller waits out: none waited for the
    # database.
    assert length(refused) >= length(ids) - DecisionLog.max_writers()
    assert length(refused) + length(waited) + length(unavailable) == length(ids)
    assert Enum.all?(refused, &(&1 < DecisionLog.budget_ms())), "a refusal waited"

    send(blocker, :release)
    assert_receive :released, 5_000
    await(fn -> DecisionLog.writers() == 0 end, 60_000)

    send(sampler, {:stop, self()})
    assert_receive {:stopped, counts}
    assert Enum.max(counts) <= DecisionLog.max_writers()
    assert Enum.all?(ids, &(rows(&1) <= 1))
  end

  test "a caller's timeout or death never stops its writer, which keeps its slot until its work " <>
         "returns",
       %{call_id: call_id, actor: actor} do
    killed_id = call_id <> "_killed"
    on_exit(fn -> delete_rows([killed_id]) end)
    blocker = hold_write_lock(self())
    assert_receive :locked, 5_000
    test = self()

    answered =
      spawn(fn -> send(test, {:answered, DecisionLog.append(actor, decision(call_id))}) end)

    killed = spawn(fn -> DecisionLog.append(actor, decision(killed_id)) end)
    await(fn -> writers(answered) != [] and writers(killed) != [] end)
    [first] = writers(answered)
    [second] = writers(killed)
    refs = for writer <- [first, second], do: Process.monitor(writer)

    # A caller killed while its writer waits: the writer stays.
    ref = Process.monitor(killed)
    Process.exit(killed, :kill)
    assert_receive {:DOWN, ^ref, :process, ^killed, :killed}
    assert Process.alive?(second)

    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 ->
        # A caller answered `:timeout` at its budget: both writers still
        # wait for the lock, holding their slots, and write once it goes.
        assert_receive {:answered, {:error, %AuditFailure{kind: :timeout}}}, 5_000
        assert Process.alive?(first) and Process.alive?(second)
        assert DecisionLog.writers() == 2
        send(blocker, :release)
        assert_receive :released, 5_000
        for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 30_000)
        assert rows(call_id) == 1 and rows(killed_id) == 1

      _postgres ->
        # Their database work returns at their deadline, the caller's
        # budget, when the pool closes the connection they waited on; their
        # slots go with it, and nothing was written.
        assert_receive {:answered, {:error, %AuditFailure{kind: :timeout}}}, 5_000
        for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 5_000)
        send(blocker, :release)
        assert_receive :released, 5_000
        assert rows(call_id) == 0 and rows(killed_id) == 0
    end

    await(fn -> DecisionLog.writers() == 0 end)
  end

  test "a writer asked to stop, as at shutdown, finishes its write first",
       %{call_id: call_id, actor: actor} do
    blocker = hold_write_lock(self())
    assert_receive :locked, 5_000

    caller = Task.async(fn -> DecisionLog.append(actor, decision(call_id)) end)
    await(fn -> writers(caller.pid) != [] end)
    [writer] = writers(caller.pid)

    stopping =
      Task.async(fn -> DynamicSupervisor.terminate_child(Arca.DecisionLog.Writers, writer) end)

    # The stop has reached the writer, which trapped it and goes on.
    await(fn -> stop_asked?(writer) end)
    assert Process.alive?(writer)
    send(blocker, :release)
    assert_receive :released, 5_000

    assert :ok = Task.await(stopping, 30_000)
    refute Process.alive?(writer)
    Task.await(caller, :infinity)
    assert rows(call_id) == 1
  end

  test "the writers start after the turn arbiter, which starts after the repo" do
    started =
      Arca.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    at = fn id -> Enum.find_index(started, &(&1 == id)) end
    assert at.(Arca.Repo) < at.(Arca.WriteTurn)
    assert at.(Arca.WriteTurn) < at.(Arca.DecisionLog.Writers)
  end

  if Arca.Repo.adapter() == Ecto.Adapters.SQLite3 do
    test "a writer killed in its native call frees its slot at its exit",
         %{call_id: call_id, actor: actor} do
      blocker = hold_write_lock(self())
      assert_receive :locked, 5_000

      caller = Task.async(fn -> DecisionLog.append(actor, decision(call_id)) end)
      await(fn -> writers(caller.pid) != [] end)
      [writer] = writers(caller.pid)
      await(fn -> stepping?(writer) end)
      Process.exit(writer, :kill)

      # Its slot is free at once, though its lock wait may still be running
      # inside the driver.
      await(fn -> DecisionLog.writers() == 0 end, 100)
      assert {:error, %AuditFailure{kind: :unavailable}} = Task.await(caller, :infinity)

      send(blocker, :release)
      assert_receive :released, 5_000
      assert rows(call_id) == 0
    end

    test "a dead writer's connection is lent again only once its disconnect has finished" do
      name = :"dead_writer_pool_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {Arca.Repo,
           name: name,
           pool_size: 1,
           pool: DBConnection.ConnectionPool,
           connection_listeners: [self()]},
          id: name
        )
      )

      assert_receive {:connected, _conn}, 5_000
      test = self()
      statement = long_statement(1_500)

      writer =
        spawn(fn ->
          Arca.Repo.put_dynamic_repo(name)

          Arca.Repo.checkout(
            fn ->
              send(test, :running)
              Arca.Repo.query!(statement, [], log: false, timeout: :infinity)
            end,
            timeout: :infinity
          )
        end)

      # Killed in its one native call, the statement it is stepping.
      assert_receive :running, 5_000
      await(fn -> stepping?(writer) end)
      Process.exit(writer, :kill)

      Task.start_link(fn ->
        Arca.Repo.put_dynamic_repo(name)
        Arca.Repo.checkout(fn -> send(test, :lent) end, timeout: 15_000)
      end)

      # The pool lends the one connection only after the dead writer's
      # native call has returned and the driver has closed it, and the
      # connection has come back: the pool reports each before it lends it,
      # so they arrive in the order they happened. At most one native call
      # outlives its writer per connection.
      assert arrivals(3) == [:disconnected, :connected, :lent]
    end

    defp arrivals(0), do: []

    defp arrivals(n) do
      receive do
        {:disconnected, _conn} -> [:disconnected | arrivals(n - 1)]
        {:connected, _conn} -> [:connected | arrivals(n - 1)]
        :lent -> [:lent | arrivals(n - 1)]
      after
        30_000 -> flunk("the pool reported nothing more")
      end
    end

    # Inside the driver running a statement: stepping it, not preparing it.
    defp stepping?(pid) do
      case Process.info(pid, :current_function) do
        {:current_function, {Exqlite.Sqlite3NIF, step, _arity}} -> step in [:step, :multi_step]
        _elsewhere -> false
      end
    end

    # A statement that runs inside the driver for about `ms`: a recursive
    # count that inserts nothing, sized from a measured one.
    defp long_statement(ms) do
      Task.async(fn ->
        {us, _} =
          :timer.tc(fn ->
            Arca.Repo.query!(
              "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 500000) " <>
                "SELECT count(*) FROM c WHERE x < 0"
            )
          end)

        rows = max(ms * div(500_000 * 1_000, max(us, 1)), 1_000)

        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < #{rows}) " <>
          "SELECT count(*) FROM c WHERE x < 0"
      end)
      |> Task.await(:infinity)
    end
  end

  defp decision(call_id) do
    Prima.Decision.new(
      call_id: call_id,
      plane: :external,
      admission: :admitted,
      tool: "t",
      action: "a",
      inserted_at: DateTime.utc_now()
    )
  end

  # Whether the supervisor's stop has reached `writer`, which traps it.
  defp stop_asked?(writer) do
    case Process.info(writer, :messages) do
      {:messages, messages} -> Enum.any?(messages, &match?({:EXIT, _supervisor, :shutdown}, &1))
      nil -> false
    end
  end

  defp delete_rows(ids) do
    Task.async(fn ->
      Arca.Repo.delete_all(from(r in "decision_logs", where: r.call_id in ^ids))
    end)
    |> Task.await(:infinity)
  end

  defp sampling(seen) do
    receive do
      {:stop, from} -> send(from, {:stopped, [DecisionLog.writers() | seen]})
    after
      2 -> sampling([DecisionLog.writers() | seen])
    end
  end

  defp await(fun, within_ms \\ 5_000),
    do: await_until(fun, System.monotonic_time(:millisecond) + within_ms)

  defp await_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the condition never held")

      true ->
        Process.sleep(1)
        await_until(fun, deadline)
    end
  end
end
