# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedThreadMembersTest do
  @moduledoc """
  The people of a shared thread: a person seated once and an identifier
  invited once, each only into an active thread, by someone seated there,
  and never while one of its people recovers from a declared restore; the
  invitations an identifier holds turned into that person's seats at
  their sign-in, except where they sit already, the thread is archived or
  a restore holds it; an invitation withdrawn and a seat removed,
  whatever the thread's status, and neither once an activation or another
  removal changed the row first (`Arca.SharedThreadMembersRaceTest`); a
  person leaving, which ends a pair or a thread left empty; and whether
  two people sit in one active thread. The people cap is
  `Arca.SharedThreadMembersCapsTest`'s. Every function is the platform's
  and refuses an athanor's actor.
  """

  use ExUnit.Case, async: true

  alias Arca.{SecurityTransitions, SharedThreadMembers, SharedThreads}
  alias Arca.Schemas.RestorePerson

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    by = person()
    {:ok, thread} = SharedThreads.create(server(), %{title: "Plans", created_by: by})
    {:ok, by: by, thread: thread}
  end

  defp server, do: Prima.Actor.system()
  defp person, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())
  defp identifier, do: "per_#{System.unique_integer([:positive])}"

  defp archived!(thread) do
    {:ok, _} = SharedThreads.archive(server(), thread.id)
    :ok
  end

  defp people(thread) do
    {:ok, people} = SharedThreadMembers.list(server(), thread.id)
    people
  end

  defp generation(thread) do
    {:ok, %{security_generation: generation}} = SharedThreads.get(server(), thread.id)
    generation
  end

  # A person with a row, seated in the thread by `by`, whose open
  # `restore_people` row a declared restore left: the thread is held until
  # they recover.
  defp recovering!(thread, by) do
    user = Arca.Test.Shares.person!()
    {:ok, _} = SharedThreadMembers.seat(server(), thread.id, user.id, by)

    Arca.Repo.insert!(%RestorePerson{
      restore_id: Prima.UUID7.generate_id("rst"),
      user_id: user.id,
      open: true
    })

    user
  end

  defp recovered!(user) do
    {:ok, [_]} =
      Arca.Repo.locking_transaction(fn -> SecurityTransitions.close_restore!(user.id) end)

    :ok
  end

  describe "seat/5" do
    test "seats a person once", %{by: by, thread: thread} do
      who = person()

      assert {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)

      assert %{
               thread_id: thread_id,
               user_id: ^who,
               person_identifier: nil,
               status: "active",
               added_by: ^by
             } = seat

      assert thread_id == thread.id
      assert "stm_" <> _ = seat.id
      assert {:ok, ^seat} = SharedThreadMembers.find(server(), thread.id, who)

      assert {:error, :conflict} = SharedThreadMembers.seat(server(), thread.id, who, by)
      assert {:ok, people} = SharedThreadMembers.list(server(), thread.id)
      assert Enum.count(people, &(&1.user_id == who)) == 1
    end

    test "refuses an archived or unknown thread and a seat for someone who is not a person",
         %{by: by, thread: thread} do
      assert {:error, :not_found} = SharedThreadMembers.seat(server(), "sth_nobody", person(), by)

      assert {:error, {:invalid, %{user_id: [_]}}} =
               SharedThreadMembers.seat(server(), thread.id, "system", by)

      :ok = archived!(thread)
      who = person()
      assert {:error, :archived} = SharedThreadMembers.seat(server(), thread.id, who, by)
      assert {:error, :not_found} = SharedThreadMembers.find(server(), thread.id, who)
    end
  end

  describe "seat/5 and invite/4" do
    test "refuse someone adding who is not seated in the thread, writing nothing",
         %{by: by, thread: thread} do
      left = person()
      {:ok, _} = SharedThreadMembers.seat(server(), thread.id, left, by)
      {:ok, _} = SharedThreadMembers.remove(server(), thread.id, left)
      before = people(thread)

      for adder <- [person(), left] do
        assert {:error, :not_member} =
                 SharedThreadMembers.seat(server(), thread.id, person(), adder)

        assert {:error, :not_member} =
                 SharedThreadMembers.invite(server(), thread.id, identifier(), adder)
      end

      assert people(thread) == before
    end

    test "refuse while one of the thread's people recovers from a restore, and admit once they have",
         %{by: by, thread: thread} do
      user = recovering!(thread, by)
      before = people(thread)
      who = person()
      id = identifier()

      assert {:error, :recovering_from_restore} =
               SharedThreadMembers.seat(server(), thread.id, who, by)

      assert {:error, :recovering_from_restore} =
               SharedThreadMembers.invite(server(), thread.id, id, by)

      assert people(thread) == before

      :ok = recovered!(user)
      assert {:ok, %{user_id: ^who}} = SharedThreadMembers.seat(server(), thread.id, who, by)

      assert {:ok, %{person_identifier: ^id}} =
               SharedThreadMembers.invite(server(), thread.id, id, by)
    end

    test "a refusal of the verify: option writes nothing and is answered",
         %{by: by, thread: thread} do
      who = person()
      before = people(thread)

      assert {:error, :issuer_gone} =
               SharedThreadMembers.seat(server(), thread.id, who, by,
                 verify: fn -> {:error, :issuer_gone} end
               )

      assert people(thread) == before
      assert {:error, :not_found} = SharedThreadMembers.find(server(), thread.id, who)

      assert {:ok, %{user_id: ^who}} =
               SharedThreadMembers.seat(server(), thread.id, who, by, verify: fn -> :ok end)
    end
  end

  describe "invite/4" do
    test "invites an identifier once, as a row naming no person", %{by: by, thread: thread} do
      id = identifier()

      assert {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert %{person_identifier: ^id, user_id: nil, status: "invited", added_by: ^by} =
               invitation

      assert {:error, :conflict} = SharedThreadMembers.invite(server(), thread.id, id, by)
    end

    test "refuses an archived or unknown thread and an empty identifier",
         %{by: by, thread: thread} do
      assert {:error, :not_found} =
               SharedThreadMembers.invite(server(), "sth_nobody", identifier(), by)

      assert {:error, {:invalid, %{person_identifier: [_]}}} =
               SharedThreadMembers.invite(server(), thread.id, "", by)

      :ok = archived!(thread)

      assert {:error, :archived} =
               SharedThreadMembers.invite(server(), thread.id, identifier(), by)
    end
  end

  describe "activate/3" do
    test "turns an identifier's invitations into the person's seats and names their threads",
         %{by: by, thread: thread} do
      {:ok, other} = SharedThreads.create(server(), %{title: "Trip", created_by: by})
      id = identifier()
      who = person()
      {:ok, _} = SharedThreadMembers.invite(server(), thread.id, id, by)
      {:ok, _} = SharedThreadMembers.invite(server(), other.id, id, by)

      assert {:ok, threads} = SharedThreadMembers.activate(server(), who, id)
      assert threads == Enum.sort([thread.id, other.id])

      for t <- [thread, other] do
        assert {:ok, %{status: "active", person_identifier: nil, added_by: ^by}} =
                 SharedThreadMembers.find(server(), t.id, who)
      end

      assert {:ok, []} = SharedThreadMembers.activate(server(), who, id)
      assert {:error, :not_found} = SharedThreadMembers.withdraw(server(), thread.id, id)
      assert {:ok, %{user_id: ^who}} = SharedThreadMembers.find(server(), thread.id, who)
    end

    test "drops an invitation where the person sits already, and keeps one in an archived thread",
         %{by: by, thread: thread} do
      {:ok, ended} = SharedThreads.create(server(), %{title: "Ended", created_by: by})
      id = identifier()
      who = person()
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)
      {:ok, _} = SharedThreadMembers.invite(server(), thread.id, id, by)
      {:ok, _} = SharedThreadMembers.invite(server(), ended.id, id, by)
      :ok = archived!(ended)

      assert {:ok, []} = SharedThreadMembers.activate(server(), who, id)

      {:ok, people} = SharedThreadMembers.list(server(), thread.id)
      assert Enum.filter(people, &(&1.user_id == who or &1.person_identifier == id)) == [seat]

      {:ok, ended_people} = SharedThreadMembers.list(server(), ended.id)

      assert [%{status: "invited", person_identifier: ^id}] =
               Enum.reject(ended_people, &(&1.user_id == by))
    end

    test "keeps an invitation to a thread a restore holds an invitation until its people recover",
         %{by: by, thread: thread} do
      id = identifier()
      who = person()
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)
      user = recovering!(thread, by)

      assert {:ok, []} = SharedThreadMembers.activate(server(), who, id)
      assert invitation in people(thread)
      assert {:error, :not_found} = SharedThreadMembers.find(server(), thread.id, who)

      :ok = recovered!(user)
      thread_id = thread.id
      assert {:ok, [^thread_id]} = SharedThreadMembers.activate(server(), who, id)

      assert {:ok, %{user_id: ^who, added_by: ^by}} =
               SharedThreadMembers.find(server(), thread.id, who)

      refute invitation in people(thread)
    end

    test "refuses someone who is not a person or an empty identifier" do
      assert {:error, {:invalid, %{user_id: [_]}}} =
               SharedThreadMembers.activate(server(), "system", identifier())

      assert {:error, {:invalid, %{person_identifier: [_]}}} =
               SharedThreadMembers.activate(server(), person(), "")
    end
  end

  describe "withdraw/3 and remove/3" do
    test "withdraw an invitation and remove a seat once each, in an archived thread too",
         %{by: by, thread: thread} do
      id = identifier()
      who = person()
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)
      :ok = archived!(thread)

      assert {:ok, ^invitation} = SharedThreadMembers.withdraw(server(), thread.id, id)
      assert {:error, :not_found} = SharedThreadMembers.withdraw(server(), thread.id, id)

      assert {:ok, ^seat} = SharedThreadMembers.remove(server(), thread.id, who)
      assert {:error, :not_found} = SharedThreadMembers.remove(server(), thread.id, who)
      assert {:error, :not_found} = SharedThreadMembers.find(server(), thread.id, who)

      assert {:ok, [%{user_id: ^by}]} = SharedThreadMembers.list(server(), thread.id)
    end

    test "withdraw takes no seat and remove takes no invitation", %{by: by, thread: thread} do
      id = identifier()
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert {:error, :not_found} = SharedThreadMembers.remove(server(), thread.id, id)
      assert {:error, :not_found} = SharedThreadMembers.withdraw(server(), thread.id, by)

      {:ok, people} = SharedThreadMembers.list(server(), thread.id)
      assert invitation in people
      assert Enum.any?(people, &(&1.user_id == by))
    end
  end

  describe "withdraw/3 and remove/3 under a restore" do
    test "are admitted while one of the thread's people recovers", %{by: by, thread: thread} do
      id = identifier()
      who = person()
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)
      _user = recovering!(thread, by)

      assert {:ok, ^invitation} = SharedThreadMembers.withdraw(server(), thread.id, id)
      assert {:ok, ^seat} = SharedThreadMembers.remove(server(), thread.id, who)
      refute invitation in people(thread) or seat in people(thread)
    end
  end

  describe "leave/3" do
    test "removes the seat and leaves a thread others still sit in active",
         %{by: by, thread: thread} do
      who = person()
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)

      assert {:ok, %{seat: ^seat, ended: false}} =
               SharedThreadMembers.leave(server(), thread.id, who)

      assert {:error, :not_found} = SharedThreadMembers.find(server(), thread.id, who)

      assert {:ok, %{status: "active", security_generation: 1}} =
               SharedThreads.get(server(), thread.id)
    end

    test "archives the thread its last seat leaves, one generation up", %{by: by, thread: thread} do
      id = identifier()
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert {:ok, %{seat: %{user_id: ^by}, ended: true}} =
               SharedThreadMembers.leave(server(), thread.id, by)

      assert {:ok, %{status: "archived", security_generation: 2, archived_at: %DateTime{}}} =
               SharedThreads.get(server(), thread.id)

      # An invitation is no one seated: it stays, in an archived thread.
      assert people(thread) == [invitation]
    end

    test "ends a pair when either of its two leaves", %{by: by} do
      other = person()
      {:ok, pair} = SharedThreads.pair(server(), by, other)

      assert {:ok, %{seat: %{user_id: ^other}, ended: true}} =
               SharedThreadMembers.leave(server(), pair.id, other)

      assert {:ok, %{status: "archived", security_generation: 2}} =
               SharedThreads.get(server(), pair.id)

      assert [%{user_id: ^by}] = people(pair)
    end

    test "leaves an archived thread archived, its generation unmoved", %{by: by, thread: thread} do
      :ok = archived!(thread)

      assert {:ok, %{seat: %{user_id: ^by}, ended: false}} =
               SharedThreadMembers.leave(server(), thread.id, by)

      assert generation(thread) == 2
      assert people(thread) == []
    end

    test "answers not_found for someone not seated there, writing nothing",
         %{by: by, thread: thread} do
      id = identifier()
      {:ok, _} = SharedThreadMembers.invite(server(), thread.id, id, by)
      before = people(thread)

      for who <- [person(), id] do
        assert {:error, :not_found} = SharedThreadMembers.leave(server(), thread.id, who)
      end

      assert {:error, :not_found} = SharedThreadMembers.leave(server(), "sth_nobody", by)
      assert people(thread) == before

      assert {:ok, %{status: "active", security_generation: 1}} =
               SharedThreads.get(server(), thread.id)
    end
  end

  describe "together?/3" do
    test "is true only for two people seated in one active thread", %{by: by, thread: thread} do
      who = person()
      stranger = person()
      id = identifier()
      {:ok, _} = SharedThreadMembers.seat(server(), thread.id, who, by)
      {:ok, _} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert {:ok, true} = SharedThreadMembers.together?(server(), by, who)
      assert {:ok, true} = SharedThreadMembers.together?(server(), who, by)
      assert {:ok, false} = SharedThreadMembers.together?(server(), by, stranger)
      assert {:ok, false} = SharedThreadMembers.together?(server(), by, id)

      :ok = archived!(thread)
      assert {:ok, false} = SharedThreadMembers.together?(server(), by, who)

      {:ok, _pair} = SharedThreads.pair(server(), by, who)
      assert {:ok, true} = SharedThreadMembers.together?(server(), who, by)
    end
  end

  describe "list/2" do
    test "names the thread's seats and invitations, oldest first", %{by: by, thread: thread} do
      who = person()
      id = identifier()
      {:ok, seat} = SharedThreadMembers.seat(server(), thread.id, who, by)
      {:ok, invitation} = SharedThreadMembers.invite(server(), thread.id, id, by)

      assert {:ok, [%{user_id: ^by}, ^seat, ^invitation]} =
               SharedThreadMembers.list(server(), thread.id)

      assert {:ok, []} = SharedThreadMembers.list(server(), "sth_nobody")
    end
  end

  test "an athanor's actor reaches no function", %{by: by, thread: thread} do
    actor = Prima.Actor.in_athanor("ath_stm_#{System.unique_integer([:positive])}")
    id = identifier()

    for call <- [
          fn -> SharedThreadMembers.seat(actor, thread.id, person(), by) end,
          fn -> SharedThreadMembers.invite(actor, thread.id, id, by) end,
          fn -> SharedThreadMembers.activate(actor, person(), id) end,
          fn -> SharedThreadMembers.withdraw(actor, thread.id, id) end,
          fn -> SharedThreadMembers.remove(actor, thread.id, by) end,
          fn -> SharedThreadMembers.leave(actor, thread.id, by) end,
          fn -> SharedThreadMembers.find(actor, thread.id, by) end,
          fn -> SharedThreadMembers.together?(actor, by, by) end,
          fn -> SharedThreadMembers.list(actor, thread.id) end
        ] do
      assert {:error, :cross_tenant} = call.()
    end

    assert {:ok, [%{user_id: ^by}]} = SharedThreadMembers.list(server(), thread.id)
  end
end

defmodule Arca.SharedThreadMembersCapsTest do
  @moduledoc """
  The people cap of a shared thread, `max_people_per_thread`: its seats
  and its invitations both count, and a seat or an invitation past it is
  refused, writing nothing. The suite's cap port admits everything
  (`Arca.Test.Caps`), so these cases install one of their own that holds
  the ceiling a case names; sync, because the port is one process-wide
  term, put back after each case.
  """

  use ExUnit.Case, async: false

  alias Arca.{SharedThreadMembers, SharedThreads}

  defmodule Ceilings do
    @moduledoc false
    # The cap port these cases install: the ceiling the calling process
    # put for a key, counted as `Sanctum.Tenancy.Caps` counts it; no
    # ceiling otherwise.
    @behaviour Prima.Caps

    def put(key, cap), do: Process.put({__MODULE__, key}, cap)

    @impl Prima.Caps
    def check_counted(%Prima.Actor{}, key, count) do
      case Process.get({__MODULE__, key}) do
        nil ->
          :ok

        cap ->
          {:ok, held} = count.()
          if held < cap, do: :ok, else: {:error, {:limit_reached, key, cap}}
      end
    end

    @impl Prima.Caps
    def check_storage(%Prima.Actor{}, _incoming), do: :ok
  end

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    installed = Prima.Caps.impl!()
    on_exit(fn -> Prima.Caps.install!(installed) end)
    Prima.Caps.install!(Ceilings)
    :ok
  end

  defp server, do: Prima.Actor.system()
  defp person, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())
  defp identifier, do: "per_#{System.unique_integer([:positive])}"

  test "counts a thread's seats and invitations, and refuses one more past the cap" do
    by = person()
    {:ok, thread} = SharedThreads.create(server(), %{title: "Plans", created_by: by})
    Ceilings.put(:max_people_per_thread, 3)

    {:ok, _} = SharedThreadMembers.seat(server(), thread.id, person(), by)
    id = identifier()
    {:ok, _} = SharedThreadMembers.invite(server(), thread.id, id, by)
    {:ok, before} = SharedThreadMembers.list(server(), thread.id)

    assert {:error, {:limit_reached, :max_people_per_thread, 3}} =
             SharedThreadMembers.seat(server(), thread.id, person(), by)

    assert {:error, {:limit_reached, :max_people_per_thread, 3}} =
             SharedThreadMembers.invite(server(), thread.id, identifier(), by)

    assert {:ok, ^before} = SharedThreadMembers.list(server(), thread.id)

    # A withdrawn invitation frees its place.
    {:ok, _} = SharedThreadMembers.withdraw(server(), thread.id, id)
    assert {:ok, _} = SharedThreadMembers.seat(server(), thread.id, person(), by)
  end
end

defmodule Arca.SharedThreadMembersRaceTest do
  @moduledoc """
  Two writers of one row of a thread's people, on real connections
  outside the sandbox: the first pauses inside its transaction right after
  its first statement on `shared_thread_members`, and the second runs until
  it has answered or waits on a lock that first statement took. Then the
  first goes on, and the answers of both agree with the rows they left: a
  withdrawal never deletes the seat an activation made of its invitation,
  and of two removals of one seat one answers it and the other
  `:not_found`.

  PostgreSQL only: on SQLite each transaction holds the one write lock
  from its start, so the second writer cannot run inside the first's.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, SharedThreadMembers, SharedThreads}
  alias Arca.Schemas.{CellLease, SharedThread, SharedThreadMember}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @pause {__MODULE__, :pause}

  defp server, do: Prima.Actor.system()
  defp person, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())
  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    hold_slot!()
    by = person()

    on_exit(fn ->
      unboxed(fn ->
        ids = from(t in SharedThread, where: t.created_by == ^by, select: t.id)
        Arca.Repo.delete_all(from(m in SharedThreadMember, where: m.thread_id in subquery(ids)))
        Arca.Repo.delete_all(from(t in SharedThread, where: t.created_by == ^by))
      end)
    end)

    {:ok, thread} =
      unboxed(fn -> SharedThreads.create(server(), %{title: "Race", created_by: by}) end)

    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.pause/4, nil)

    {:ok, by: by, thread: thread}
  end

  test "a withdrawal and an activation of one invitation agree on which came first",
       %{by: by, thread: thread} do
    who = person()
    id = "per_#{System.unique_integer([:positive])}"
    {:ok, _} = unboxed(fn -> SharedThreadMembers.invite(server(), thread.id, id, by) end)

    withdrawal = paused(fn -> SharedThreadMembers.withdraw(server(), thread.id, id) end)
    assert_receive {:paused, withdrawer}, 5_000

    activation = watched(fn -> SharedThreadMembers.activate(server(), who, id) end)
    activated = settled(activation)
    send(withdrawer, :continue)

    withdrawn = Task.await(withdrawal, 10_000)
    activated = answer(activated, activation)
    seat = unboxed(fn -> SharedThreadMembers.find(server(), thread.id, who) end)

    case withdrawn do
      {:ok, %{status: "invited", person_identifier: ^id}} ->
        assert {:ok, []} = activated
        assert {:error, :not_found} = seat

      {:error, :not_found} ->
        assert {:ok, [_]} = activated
        assert {:ok, %{user_id: ^who}} = seat

      other ->
        flunk("the withdrawal answered #{inspect(other)}")
    end
  end

  test "of two removals of one seat, one answers it and the other not_found",
       %{by: by, thread: thread} do
    first = paused(fn -> SharedThreadMembers.remove(server(), thread.id, by) end)
    assert_receive {:paused, remover}, 5_000

    second = watched(fn -> SharedThreadMembers.remove(server(), thread.id, by) end)
    seconded = settled(second)
    send(remover, :continue)

    answers = [Task.await(first, 10_000), answer(seconded, second)]

    assert Enum.count(answers, &match?({:ok, %{user_id: ^by, status: "active"}}, &1)) == 1,
           inspect(answers)

    assert Enum.count(answers, &(&1 == {:error, :not_found})) == 1, inspect(answers)

    assert {:error, :not_found} =
             unboxed(fn -> SharedThreadMembers.find(server(), thread.id, by) end)
  end

  @doc false
  # The telemetry handler: the process that set the pause stops after its
  # first statement on `shared_thread_members`, inside its transaction,
  # until the case lets it go on.
  def pause(_event, _measurements, %{query: query}, _config) do
    case Process.get(@pause) do
      {test, fragment} ->
        if String.contains?(query, fragment) do
          Process.delete(@pause)
          send(test, {:paused, self()})

          receive do
            :continue -> :ok
          after
            15_000 -> raise "paused past the case"
          end
        end

      nil ->
        :ok
    end
  end

  defp paused(fun) do
    test = self()

    Task.async(fn ->
      Process.put(@pause, {test, ~s("shared_thread_members")})
      unboxed(fn -> outcome(fun) end)
    end)
  end

  # The second writer, which names its backend first so the case can see
  # it wait.
  defp watched(fun) do
    test = self()

    Task.async(fn ->
      unboxed(fn ->
        %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
        send(test, {:backend, backend})
        outcome(fun)
      end)
    end)
  end

  # What the writer ended with, a raise included, so a writer that raises
  # is a wrong answer and not a crashed case.
  defp outcome(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  end

  # The second writer answered, or waits on a lock.
  defp settled(task) do
    assert_receive {:backend, backend}, 5_000
    settled(task, backend, System.monotonic_time(:millisecond) + 10_000)
  end

  defp settled(task, backend, deadline) do
    case Task.yield(task, 20) do
      {:ok, result} ->
        {:answered, result}

      nil ->
        cond do
          waiting?(backend) -> :waiting
          System.monotonic_time(:millisecond) < deadline -> settled(task, backend, deadline)
          true -> flunk("backend #{backend} neither answered nor waited on a lock")
        end
    end
  end

  defp answer({:answered, result}, _task), do: result
  defp answer(:waiting, task), do: Task.await(task, 10_000)

  defp waiting?(backend) do
    unboxed(fn ->
      %{rows: rows} =
        Arca.Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend])

      rows == [["Lock"]]
    end)
  end

  # This member's slot, taken on a real connection so every connection
  # reads the lease. Each process-wide value is restored after the case,
  # registered before it changes (`Prima.Test.Env`), and the lease row is
  # deleted.
  defp hold_slot! do
    node = "node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)
    end)

    for key <- @slot_keys, do: Prima.Test.Env.erase_persistent_term(key)
    Prima.Test.Env.put_app_env(:arca, :control_plane_claim_enabled, true)
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)
    slot
  end
end
