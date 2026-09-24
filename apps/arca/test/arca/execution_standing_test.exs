# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionStandingTest do
  @moduledoc """
  The execution writes under a grant, in the sandbox: each asks its check
  first and writes nothing when the check refuses or cannot answer, a
  write missing its grant or its check is refused, and a stamp that is
  not the attempt's own matches nothing. A child inherits its parent's
  stamp and a successor its predecessor's; neither is rebuilt from the
  estate as it stands.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.ExecutionAttempts
  alias Arca.Test.Actor

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Actor.athanor!()
    {:ok, actor: Actor.local()}
  end

  defp attrs(actor, overrides \\ %{}) do
    Map.merge(
      %{
        id: "exec_std_#{System.unique_integer([:positive])}",
        reference: "reagent:local.standing:0.1.0",
        user_id: actor.user_id,
        athanor_id: actor.athanor_id,
        component_type: "reagent"
      },
      overrides
    )
  end

  defp unavailable, do: fn %Cyfr.ExecutionGrant{} -> {:error, :unavailable} end

  test "an admission stamps its attempt with the grant, and refuses without one", %{actor: actor} do
    grant = Actor.grant(actor.athanor_id)

    assert {:ok, %{attempt: %{athanor_generation: generation}}} =
             Arca.Execution.admit(attrs(actor), Actor.standing(actor.athanor_id))

    assert generation == grant.generation

    missing = attrs(actor)
    assert {:error, :missing_grant} = Arca.Execution.admit(missing, [])
    assert {:error, :missing_grant} = Arca.Execution.admit(missing, grant: grant)
    assert {:error, :missing_grant} = Arca.Execution.admit(missing, verify: &Actor.admits/1)

    assert {:error, :missing_grant} =
             Arca.Execution.admit(missing,
               grant: %{grant | generation: 0},
               verify: &Actor.admits/1
             )

    # A grant of another estate is not this row's.
    assert {:error, :not_standing} =
             Arca.Execution.admit(missing, Actor.standing("ath_other"))

    refute Arca.Repo.get(Arca.Schemas.Execution, missing.id)
  end

  test "a check that cannot answer admits, renews, claims and writes nothing", %{actor: actor} do
    grant = Actor.grant(actor.athanor_id)
    refused = attrs(actor)

    assert {:error, :unavailable} =
             Arca.Execution.admit(refused, grant: grant, verify: unavailable())

    refute Arca.Repo.get(Arca.Schemas.Execution, refused.id)

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(attrs(actor), Actor.standing(actor.athanor_id))

    down = [grant: :stored, verify: unavailable()]
    later = DateTime.add(DateTime.utc_now(), 300, :second)

    assert :unavailable = ExecutionAttempts.renew(attempt.attempt, later, down)
    assert {:error, :unavailable} = ExecutionAttempts.claim(actor, attempt.attempt, 1, "r", down)
    assert :ok = ExecutionAttempts.claim(actor, attempt.attempt, 1, "r", Actor.stored())

    assert {:error, :unavailable} =
             ExecutionAttempts.renew_held(
               actor,
               attempt.attempt,
               %{service_id: nil, boot_id: attempt.boot_id, runner: "r"},
               down
             )

    assert {:error, :unavailable} = ExecutionAttempts.held?(actor, attempt.attempt, 1, "r", down)

    test = self()

    write = %{
      op: :put,
      path: ["data", "x.txt"],
      io: fn ->
        send(test, :ran)
        :ok
      end
    }

    assert {:error, :unavailable} =
             ExecutionAttempts.while_held(actor, attempt.attempt, 1, "r", write, down)

    refute_received :ran
    assert [] = ExecutionAttempts.write_intents(actor, attempt.attempt)

    assert {:error, :unavailable} =
             Arca.Execution.record_end(
               actor,
               execution.id,
               "completed",
               %{completed_at: DateTime.utc_now(), duration_ms: 1},
               attempt.attempt,
               down
             )

    assert %{status: "running"} = Arca.Repo.get!(Arca.Schemas.Execution, execution.id)
    assert %{lease_until: lease} = ExecutionAttempts.get(actor, attempt.attempt)
    assert DateTime.compare(lease, later) != :eq
  end

  test "a stamp that is not the attempt's own writes nothing", %{actor: actor} do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(attrs(actor), Actor.standing(actor.athanor_id))

    grant = Actor.grant(actor.athanor_id)
    stale = [grant: %{grant | generation: grant.generation + 1}, verify: &Actor.admits/1]
    later = DateTime.add(DateTime.utc_now(), 300, :second)

    assert :lost = ExecutionAttempts.renew(attempt.attempt, later, stale)
    assert {:error, :lost} = ExecutionAttempts.claim(actor, attempt.attempt, 1, "r", stale)
    assert false == ExecutionAttempts.held?(actor, attempt.attempt, 1, "r", stale)

    assert {:error, :not_standing} =
             Arca.Execution.record_end(
               actor,
               execution.id,
               "failed",
               %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "x"},
               attempt.attempt,
               stale
             )

    assert {:error, :not_standing} =
             ExecutionAttempts.takeover(actor, execution.id,
               boot_id: "boot-2",
               lease_until: later,
               grant: stale[:grant],
               verify: &Actor.admits/1
             )

    assert %{status: "running", current_attempt: current} =
             Arca.Repo.get!(Arca.Schemas.Execution, execution.id)

    assert current == attempt.attempt
  end

  test "a completion is recorded only under a grant that stands and is the row's own", %{
    actor: actor
  } do
    {:ok, %{execution: execution}} =
      Arca.Execution.admit(attrs(actor), Actor.standing(actor.athanor_id))

    done = %{completed_at: DateTime.utc_now(), duration_ms: 1, status: "completed"}
    grant = Actor.grant(actor.athanor_id)
    stale = %{grant | generation: grant.generation + 1}

    assert {:error, :missing_grant} = Arca.Execution.record_complete(actor, execution.id, done)

    assert {:error, :missing_grant} =
             Arca.Execution.record_complete(actor, execution.id, done, grant: grant)

    assert {:error, :unavailable} =
             Arca.Execution.record_complete(actor, execution.id, done,
               grant: :stored,
               verify: unavailable()
             )

    assert {:error, :not_standing} =
             Arca.Execution.record_complete(actor, execution.id, done,
               grant: stale,
               verify: &Actor.admits/1
             )

    assert %{status: "running"} = Arca.Repo.get!(Arca.Schemas.Execution, execution.id)

    assert {:ok, %{status: "completed"}} =
             Arca.Execution.record_complete(actor, execution.id, done, Actor.stored())

    # A row with no attempt has no stamp to read: it needs an explicit grant.
    {:ok, _} =
      Arca.Execution.record_start(
        Map.merge(attrs(actor, %{id: "exec_bare_#{System.unique_integer([:positive])}"}), %{
          started_at: DateTime.utc_now(),
          status: "running"
        })
      )

    [bare] =
      Arca.Repo.all(
        from(e in Arca.Schemas.Execution,
          where: e.athanor_id == ^actor.athanor_id and is_nil(e.current_attempt)
        )
      )

    assert {:error, :missing_grant} =
             Arca.Execution.record_complete(actor, bare.id, done, Actor.stored())

    assert {:ok, _} =
             Arca.Execution.record_complete(
               actor,
               bare.id,
               done,
               Actor.standing(actor.athanor_id)
             )
  end

  test "a child inherits its parent's stamp, and a successor its predecessor's", %{actor: actor} do
    {:ok, %{execution: parent, attempt: parent_attempt}} =
      Arca.Execution.admit(attrs(actor), Actor.standing(actor.athanor_id))

    grant = Actor.grant(actor.athanor_id)
    child = attrs(actor, %{parent_execution_id: parent.id, root_execution_id: parent.id})

    assert {:error, :not_standing} =
             Arca.Execution.admit(child,
               parent_attempt: parent_attempt.attempt,
               grant: %{grant | generation: grant.generation + 1},
               verify: &Actor.admits/1
             )

    assert {:ok, %{attempt: %{athanor_generation: inherited}}} =
             Arca.Execution.admit(child,
               parent_attempt: parent_attempt.attempt,
               grant: grant,
               verify: &Actor.admits/1
             )

    assert inherited == parent_attempt.athanor_generation

    assert {:ok, %{attempt: successor}} =
             ExecutionAttempts.takeover(
               actor,
               parent.id,
               [boot_id: "boot-2", lease_until: ExecutionAttempts.lease_until()] ++
                 Actor.stored()
             )

    assert successor.athanor_generation == parent_attempt.athanor_generation
    assert {:ok, ^grant} = ExecutionAttempts.grant(actor, parent.id)
  end
end

defmodule Arca.ExecutionStandingLockTest do
  @moduledoc """
  An admission and an archive under two real connections, outside the
  sandbox, in both orders. Each serializes on the estate's row — on
  PostgreSQL by waiting on the row, on SQLite by waiting at the lock its transaction takes at entry
  — and the one that waits acts on what the other committed: an admission
  that committed first is retired by the archive, and one that waited
  reads the archive and admits nothing. On PostgreSQL the checks hold the
  row shared: two never wait for each other, and an archive waits for
  every one of them.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Schemas.{ApiKey, Athanor, ExecutionAttempt}
  alias Arca.Test.Actor
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    athanor_id = Cyfr.UUID7.generate_id("ath")
    n = System.unique_integer([:positive])

    {:ok, _} =
      unboxed(fn ->
        Arca.Athanors.insert(Cyfr.Actor.system(), %{
          id: athanor_id,
          kind: "group",
          name: "Barrier #{n}",
          slug: "std-barrier-#{n}",
          created_by: "system"
        })
      end)

    on_exit(fn ->
      unboxed(fn ->
        ids = from(e in Arca.Schemas.Execution, where: e.athanor_id == ^athanor_id, select: e.id)

        Arca.Repo.delete_all(
          from(i in "execution_events", where: i.execution_id in subquery(ids))
        )

        Arca.Repo.delete_all(from(a in ExecutionAttempt, where: a.athanor_id == ^athanor_id))

        Arca.Repo.delete_all(
          from(e in Arca.Schemas.Execution, where: e.athanor_id == ^athanor_id)
        )

        Arca.Repo.delete_all(from(k in ApiKey, where: k.athanor_id == ^athanor_id))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^athanor_id))
      end)
    end)

    {:ok, athanor_id: athanor_id}
  end

  defp attrs(athanor_id) do
    %{
      id: Cyfr.UUID7.execution_id(),
      reference: "reagent:local.barrier:0.1.0",
      user_id: "usr_barrier",
      athanor_id: athanor_id,
      component_type: "reagent"
    }
  end

  # The identity domain's check, which stops once it holds the estate's
  # row until the test says go.
  defp holding(test, label) do
    fn grant ->
      answer = Actor.verify(grant)
      send(test, {:holding, label})

      receive do
        :go -> answer
      end
    end
  end

  defp archive(athanor_id, verify) do
    Arca.SecurityTransitions.archive_athanor(Cyfr.Actor.system(), athanor_id, verify: verify)
  end

  test "an admission holding the estate retires under the archive that waited for it", %{
    athanor_id: athanor_id
  } do
    test = self()
    grant = unboxed(fn -> Actor.grant(athanor_id) end)
    row = attrs(athanor_id)

    admitter =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Execution.admit(row, grant: grant, verify: holding(test, :admission))
        end)
      end)

    assert_receive {:holding, :admission}, 5_000

    archiver = Task.async(fn -> unboxed(fn -> archive(athanor_id, fn _ -> :ok end) end) end)
    refute Task.yield(archiver, 300), "the archive decided while the admission held the estate"

    send(admitter.pid, :go)
    assert {:ok, %{attempt: attempt}} = Task.await(admitter, 25_000)
    assert {:ok, %{archived_athanor_ids: [^athanor_id]}} = Task.await(archiver, 25_000)

    # The work it admitted is retired: nothing renews it, and the scan
    # finds it.
    later = DateTime.add(DateTime.utc_now(), 300, :second)

    unboxed(fn ->
      assert :lost =
               Arca.ExecutionAttempts.renew(attempt.attempt, later,
                 grant: :stored,
                 verify: &Actor.verify/1
               )

      assert {:ok, retired} = scan(athanor_id)
      assert [{_, found, ^athanor_id, generation}] = retired
      assert found == attempt.attempt and generation == grant.generation
    end)
  end

  test "an admission waiting behind an archive reads it and admits nothing", %{
    athanor_id: athanor_id
  } do
    test = self()
    grant = unboxed(fn -> Actor.grant(athanor_id) end)
    row = attrs(athanor_id)

    archiver =
      Task.async(fn ->
        unboxed(fn ->
          archive(athanor_id, fn _rows ->
            send(test, {:holding, :archive})

            receive do
              :go -> :ok
            end
          end)
        end)
      end)

    assert_receive {:holding, :archive}, 5_000

    admitter =
      Task.async(fn ->
        unboxed(fn -> Arca.Execution.admit(row, grant: grant, verify: &Actor.verify/1) end)
      end)

    refute Task.yield(admitter, 300), "the admission decided while the archive held the estate"

    send(archiver.pid, :go)
    assert {:ok, %{archived_athanor_ids: [^athanor_id]}} = Task.await(archiver, 25_000)

    # Had it acted on a read from before its wait, it would have admitted.
    assert {:error, :not_standing} = Task.await(admitter, 25_000)
    unboxed(fn -> refute Arca.Repo.get(Arca.Schemas.Execution, row.id) end)
  end

  @tag :postgres
  test "two verifications share the estate, and an archive waits behind either", %{
    athanor_id: athanor_id
  } do
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3 do
      # One writer at a time: there is no shared row lock for two
      # verifications to hold together.
      :ok
    else
      test = self()
      grant = unboxed(fn -> Actor.grant(athanor_id) end)

      verification = fn label, transaction ->
        Task.async(fn ->
          unboxed(fn -> transaction.(fn -> holding(test, label).(grant) end) end)
        end)
      end

      # A write's check and a read-only effect's check, each holding the
      # estate row until told to go.
      writer = verification.(:writer, &Arca.Repo.locking_transaction/1)
      assert_receive {:holding, :writer}, 5_000

      reader = verification.(:reader, &Arca.Repo.read_transaction/1)
      assert_receive {:holding, :reader}, 5_000

      archiver = Task.async(fn -> unboxed(fn -> archive(athanor_id, fn _ -> :ok end) end) end)
      refute Task.yield(archiver, 300), "the archive locked an estate two checks held"

      send(writer.pid, :go)
      assert {:ok, :ok} = Task.await(writer, 5_000)
      refute Task.yield(archiver, 300), "the archive locked an estate a check still held"

      send(reader.pid, :go)
      assert {:ok, :ok} = Task.await(reader, 5_000)
      assert {:ok, %{archived_athanor_ids: [^athanor_id]}} = Task.await(archiver, 25_000)

      # A check that begins after the archive reads its result.
      assert {:ok, {:error, :not_standing}} =
               unboxed(fn ->
                 Arca.Repo.read_transaction(fn -> Actor.verify(grant) end)
               end)
    end
  end

  defp scan(athanor_id, cursor \\ nil, acc \\ []) do
    case Arca.ExecutionStanding.retired_attempts(Cyfr.Actor.system(), cursor, 50) do
      {:ok, []} -> {:ok, Enum.filter(acc, &(elem(&1, 2) == athanor_id))}
      {:ok, page} -> scan(athanor_id, page |> List.last() |> elem(1), acc ++ page)
    end
  end
end
