# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedThreadMembersTest do
  @moduledoc """
  The people of a shared thread: a person seated once and an identifier
  invited once, each only into an active thread; the invitations an
  identifier holds turned into that person's seats at their sign-in,
  except where they sit already or the thread is archived; an invitation
  withdrawn and a seat removed, whatever the thread's status, and
  neither once an activation or another removal changed the row first
  (`Arca.SharedThreadMembersRaceTest`). Every function is the platform's
  and refuses an athanor's actor.
  """

  use ExUnit.Case, async: true

  alias Arca.{SharedThreadMembers, SharedThreads}

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

  describe "seat/4" do
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
          fn -> SharedThreadMembers.find(actor, thread.id, by) end,
          fn -> SharedThreadMembers.list(actor, thread.id) end
        ] do
      assert {:error, :cross_tenant} = call.()
    end

    assert {:ok, [%{user_id: ^by}]} = SharedThreadMembers.list(server(), thread.id)
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
