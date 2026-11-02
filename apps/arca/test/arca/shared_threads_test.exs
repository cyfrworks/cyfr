# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SharedThreadsTest do
  @moduledoc """
  Shared threads: a thread of people made with its first seat, found by its
  id and listed by the people seated in it, renamed, archived and reopened
  with its generation raised each time; and a pair of two people, made once
  and found by either of them, which two callers asking at once cannot both
  make (`Arca.SharedThreadsRaceTest`). The caps on threads and pairs are
  `Arca.SharedThreadsCapsTest`'s. Every function is the platform's and
  refuses an athanor's actor.
  """

  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Arca.{SharedMessages, SharedThreadMembers, SharedThreads}
  alias Arca.Schemas.SharedThread

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()
  defp person, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())

  defp thread!(title \\ "Plans") do
    by = person()
    {:ok, thread} = SharedThreads.create(server(), %{title: title, created_by: by})
    {thread, by}
  end

  # A thread of people that `people` sit in together, made by someone else,
  # so their own counts are untouched: what a pair asks of its two.
  defp together!(people) do
    host = person()
    {:ok, thread} = SharedThreads.create(server(), %{title: "Shared", created_by: host})
    for who <- people, do: {:ok, _} = SharedThreadMembers.seat(server(), thread.id, who, host)
    thread
  end

  describe "create/2" do
    test "makes an active titled thread at generation 1 and seats its maker" do
      by = person()

      assert {:ok, thread} = SharedThreads.create(server(), %{title: "Plans", created_by: by})

      assert %{
               kind: "shared",
               title: "Plans",
               pair_of: nil,
               status: "active",
               created_by: ^by,
               archived_at: nil,
               last_message_at: nil,
               security_generation: 1
             } = thread

      assert "sth_" <> _ = thread.id
      assert {:ok, ^thread} = SharedThreads.get(server(), thread.id)

      assert {:ok, [%{user_id: ^by, status: "active", added_by: ^by}]} =
               SharedThreadMembers.list(server(), thread.id)
    end

    test "refuses a missing title or a maker who is not a person, writing nothing" do
      before = Arca.Repo.aggregate(SharedThread, :count)

      assert {:error, {:invalid, %{title: [_]}}} =
               SharedThreads.create(server(), %{title: "  ", created_by: person()})

      assert {:error, {:invalid, %{title: [_], created_by: [_]}}} =
               SharedThreads.create(server(), %{created_by: "webhook:x"})

      assert Arca.Repo.aggregate(SharedThread, :count) == before
    end
  end

  describe "get/2" do
    test "answers not_found for an id no thread holds" do
      assert {:error, :not_found} = SharedThreads.get(server(), "sth_nobody")
    end
  end

  describe "pair/3" do
    test "makes an untitled pair of the two people, seated, and either of them finds it again" do
      [a, b] = Enum.sort([person(), person()])
      together!([a, b])

      assert {:ok, pair} = SharedThreads.pair(server(), b, a)

      assert %{kind: "pair", title: nil, status: "active", created_by: ^b} = pair
      assert pair.pair_of == a <> ":" <> b

      {:ok, seats} = SharedThreadMembers.list(server(), pair.id)
      assert Enum.sort(Enum.map(seats, & &1.user_id)) == [a, b]
      assert Enum.all?(seats, &(&1.status == "active" and &1.added_by == b))

      assert {:ok, ^pair} = SharedThreads.pair(server(), a, b)
      assert {:ok, ^pair} = SharedThreads.pair(server(), b, a)
      assert active_pairs(pair.pair_of) == 1
    end

    test "makes a new pair once the old one is archived" do
      a = person()
      b = person()
      together!([a, b])
      {:ok, old} = SharedThreads.pair(server(), a, b)
      {:ok, _} = SharedThreads.archive(server(), old.id, old.created_by)

      assert {:ok, new} = SharedThreads.pair(server(), b, a)
      assert new.id != old.id
      assert new.pair_of == old.pair_of
      assert active_pairs(new.pair_of) == 1
    end

    test "is found or made only for two who sit together in an active thread" do
      [a, b] = [person(), person()]

      assert {:error, :not_together} = SharedThreads.pair(server(), a, b)

      shared = together!([a, b])
      {:ok, pair} = SharedThreads.pair(server(), a, b)

      # The pair itself is a thread they share; once it ends and the other
      # thread is archived, they share none, and none is made again.
      {:ok, _} = SharedThreads.archive(server(), pair.id, a)
      {:ok, _} = SharedThreads.archive(server(), shared.id, shared.created_by)
      assert {:error, :not_together} = SharedThreads.pair(server(), b, a)
      assert active_pairs(pair.pair_of) == 0
    end

    test "refuses one person twice or someone who is not a person" do
      a = person()

      assert {:error, {:invalid, %{people: [_]}}} = SharedThreads.pair(server(), a, a)
      assert {:error, {:invalid, %{people: [_]}}} = SharedThreads.pair(server(), a, "system")
    end
  end

  describe "list_for/2" do
    test "names the threads a person sits in, archived ones too, the latest message first" do
      {quiet, by} = thread!("Quiet")
      {:ok, busy} = SharedThreads.create(server(), %{title: "Busy", created_by: by})
      {:ok, ended} = SharedThreads.create(server(), %{title: "Ended", created_by: by})
      {:ok, _} = SharedThreads.archive(server(), ended.id, ended.created_by)
      {:ok, _} = SharedMessages.append(server(), busy.id, %{author: by, content: "hi"})

      {other, other_by} = thread!("Not theirs")
      {:ok, _} = SharedThreadMembers.invite(server(), other.id, "per_#{by}", other_by)

      assert {:ok, threads} = SharedThreads.list_for(server(), by)
      assert hd(threads).id == busy.id
      assert Enum.sort(Enum.map(threads, & &1.id)) == Enum.sort([quiet.id, busy.id, ended.id])

      {:ok, _} = SharedThreadMembers.remove(server(), quiet.id, by, quiet.created_by)
      {:ok, threads} = SharedThreads.list_for(server(), by)
      refute quiet.id in Enum.map(threads, & &1.id)
    end
  end

  describe "rename/3" do
    test "gives a thread of people a new title" do
      {thread, _} = thread!()

      assert {:ok, %{title: "Trip"}} =
               SharedThreads.rename(server(), thread.id, thread.created_by, "Trip")

      assert {:ok, %{title: "Trip"}} = SharedThreads.get(server(), thread.id)
    end

    test "refuses a pair, an unknown thread and an empty title" do
      [a, b] = [person(), person()]
      together!([a, b])
      {:ok, pair} = SharedThreads.pair(server(), a, b)
      {thread, _} = thread!()

      assert {:error, :pair} = SharedThreads.rename(server(), pair.id, pair.created_by, "Trip")
      assert {:error, :not_found} = SharedThreads.rename(server(), "sth_nobody", person(), "Trip")

      assert {:error, {:invalid, %{title: [_]}}} =
               SharedThreads.rename(server(), thread.id, thread.created_by, "")

      assert {:ok, %{title: nil}} = SharedThreads.get(server(), pair.id)
    end
  end

  describe "archive/2 and unarchive/2" do
    test "archive and reopen a thread, each raising its generation once" do
      {thread, _} = thread!()

      assert {:ok, archived} = SharedThreads.archive(server(), thread.id, thread.created_by)
      assert %{status: "archived", security_generation: 2} = archived
      assert %DateTime{} = archived.archived_at

      assert {:ok, ^archived} = SharedThreads.archive(server(), thread.id, thread.created_by)

      assert {:ok, reopened} = SharedThreads.unarchive(server(), thread.id, thread.created_by)
      assert %{status: "active", archived_at: nil, security_generation: 3} = reopened
      assert {:ok, ^reopened} = SharedThreads.unarchive(server(), thread.id, thread.created_by)
    end

    test "a pair stays ended, and an unknown thread is not found" do
      [a, b] = [person(), person()]
      together!([a, b])
      {:ok, pair} = SharedThreads.pair(server(), a, b)
      {:ok, _} = SharedThreads.archive(server(), pair.id, pair.created_by)

      assert {:error, :pair} = SharedThreads.unarchive(server(), pair.id, pair.created_by)
      assert {:ok, %{status: "archived"}} = SharedThreads.get(server(), pair.id)
      assert {:error, :not_found} = SharedThreads.archive(server(), "sth_nobody", person())
      assert {:error, :not_found} = SharedThreads.unarchive(server(), "sth_nobody", person())
    end
  end

  test "an athanor's actor reaches no function" do
    {thread, by} = thread!()
    actor = Prima.Actor.in_athanor("ath_sth_#{System.unique_integer([:positive])}")

    for call <- [
          fn -> SharedThreads.create(actor, %{title: "x", created_by: by}) end,
          fn -> SharedThreads.pair(actor, by, person()) end,
          fn -> SharedThreads.get(actor, thread.id) end,
          fn -> SharedThreads.list_for(actor, by) end,
          fn -> SharedThreads.rename(actor, thread.id, thread.created_by, "x") end,
          fn -> SharedThreads.archive(actor, thread.id, thread.created_by) end,
          fn -> SharedThreads.unarchive(actor, thread.id, thread.created_by) end
        ] do
      assert {:error, :cross_tenant} = call.()
    end

    assert {:ok, ^thread} = SharedThreads.get(server(), thread.id)
  end

  describe "the one acting" do
    test "a rename, an archive and a reopening by someone not seated in the thread change nothing" do
      {thread, by} = thread!()
      stranger = person()

      assert {:error, :not_member} = SharedThreads.rename(server(), thread.id, stranger, "Theirs")
      assert {:error, :not_member} = SharedThreads.archive(server(), thread.id, stranger)

      {:ok, _} = SharedThreads.archive(server(), thread.id, by)
      assert {:error, :not_member} = SharedThreads.unarchive(server(), thread.id, stranger)

      assert {:ok, %{title: "Plans", status: "archived", security_generation: 2}} =
               SharedThreads.get(server(), thread.id)
    end

    test "a member removed is refused as anyone not seated is" do
      {thread, by} = thread!()
      who = person()
      {:ok, _} = SharedThreadMembers.seat(server(), thread.id, who, by)
      {:ok, _} = SharedThreadMembers.remove(server(), thread.id, who, by)

      assert {:error, :not_member} = SharedThreads.rename(server(), thread.id, who, "Mine")
      assert {:error, :not_member} = SharedThreads.archive(server(), thread.id, who)
      assert {:ok, %{title: "Plans", status: "active"}} = SharedThreads.get(server(), thread.id)
    end
  end

  defp active_pairs(pair_of),
    do:
      Arca.Repo.aggregate(
        from(t in SharedThread, where: t.pair_of == ^pair_of and t.status == "active"),
        :count
      )
end

defmodule Arca.SharedThreadsCapsTest do
  @moduledoc """
  The caps a shared thread's making counts: `max_shared_threads_per_person`
  bounds the threads a person made that stand active, and
  `max_pairs_per_person` the active pairs each of a new pair's two sits
  in, while a pair found again is not counted. The suite's cap port admits
  everything (`Arca.Test.Caps`), so these cases install one of their own
  that holds the ceiling a case names; sync, because the port is one
  process-wide term, put back after each case.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.SharedThreads
  alias Arca.Schemas.SharedThread

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

  defp made_by(by),
    do: Arca.Repo.aggregate(from(t in SharedThread, where: t.created_by == ^by), :count)

  # A thread of people that `people` sit in together, made by someone else,
  # so their own counts are untouched: what a pair asks of its two.
  defp together!(people) do
    host = person()
    {:ok, thread} = SharedThreads.create(server(), %{title: "Shared", created_by: host})

    for who <- people,
        do: {:ok, _} = Arca.SharedThreadMembers.seat(server(), thread.id, who, host)

    thread
  end

  test "a person at max_shared_threads_per_person makes no more, and an archived one frees its place" do
    by = person()
    Ceilings.put(:max_shared_threads_per_person, 2)
    {:ok, first} = SharedThreads.create(server(), %{title: "One", created_by: by})
    {:ok, _} = SharedThreads.create(server(), %{title: "Two", created_by: by})

    assert {:error, {:limit_reached, :max_shared_threads_per_person, 2}} =
             SharedThreads.create(server(), %{title: "Three", created_by: by})

    assert made_by(by) == 2

    # Another person's threads are theirs to count, and a pair is no thread
    # of people.
    assert {:ok, _} = SharedThreads.create(server(), %{title: "Theirs", created_by: person()})
    other = person()
    together!([by, other])
    assert {:ok, _} = SharedThreads.pair(server(), by, other)

    {:ok, _} = SharedThreads.archive(server(), first.id, first.created_by)

    assert {:ok, %{title: "Three"}} =
             SharedThreads.create(server(), %{title: "Three", created_by: by})
  end

  test "a reopening counts the creator's active threads as a creation does" do
    by = person()
    Ceilings.put(:max_shared_threads_per_person, 1)
    {:ok, first} = SharedThreads.create(server(), %{title: "One", created_by: by})
    {:ok, _} = SharedThreads.archive(server(), first.id, by)
    {:ok, second} = SharedThreads.create(server(), %{title: "Two", created_by: by})

    assert {:error, {:limit_reached, :max_shared_threads_per_person, 1}} =
             SharedThreads.unarchive(server(), first.id, by)

    assert {:ok, %{status: "archived", security_generation: 2}} =
             SharedThreads.get(server(), first.id)

    {:ok, _} = SharedThreads.archive(server(), second.id, by)
    assert {:ok, %{status: "active"}} = SharedThreads.unarchive(server(), first.id, by)
  end

  test "a new pair is refused when either of its two is at max_pairs_per_person, " <>
         "and a pair found again is not counted" do
    [a, b, c, d] = for _ <- 1..4, do: person()
    together!([a, b, c, d])
    Ceilings.put(:max_pairs_per_person, 1)
    {:ok, pair} = SharedThreads.pair(server(), a, b)

    assert {:error, {:limit_reached, :max_pairs_per_person, 1}} =
             SharedThreads.pair(server(), a, c)

    assert {:error, {:limit_reached, :max_pairs_per_person, 1}} =
             SharedThreads.pair(server(), c, a)

    assert made_by(c) == 0

    assert {:ok, ^pair} = SharedThreads.pair(server(), b, a)
    assert {:ok, ^pair} = SharedThreads.pair(server(), a, b)
    assert {:ok, %{kind: "pair"}} = SharedThreads.pair(server(), c, d)
  end
end

defmodule Arca.SharedThreadsRaceTest do
  @moduledoc """
  Two callers making one pair at once, on real connections outside the
  sandbox: one writes the pair and every other answers it. On PostgreSQL
  a loser's insert waits for the winner's commit and writes nothing; on
  SQLite the second transaction waits at its entry and finds the pair.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ControlPlane, SharedThreads}
  alias Arca.Schemas.{CellLease, SharedThread, SharedThreadMember}
  alias Ecto.Adapters.SQL.Sandbox

  defp server, do: Prima.Actor.system()
  defp person, do: Prima.UUID7.generate_id(Prima.PersonId.prefix())
  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  test "both answer the one pair, and one pair with two seats is written" do
    hold_slot!()
    a = person()
    b = person()
    pair_of = Enum.join(Enum.sort([a, b]), ":")

    {:ok, shared} =
      unboxed(fn -> SharedThreads.create(server(), %{title: "Shared", created_by: a}) end)

    {:ok, _} = unboxed(fn -> Arca.SharedThreadMembers.seat(server(), shared.id, b, a) end)

    on_exit(fn ->
      unboxed(fn ->
        ids =
          from(t in SharedThread,
            where: t.pair_of == ^pair_of or t.id == ^shared.id,
            select: t.id
          )

        Arca.Repo.delete_all(from(m in SharedThreadMember, where: m.thread_id in subquery(ids)))

        Arca.Repo.delete_all(
          from(t in SharedThread, where: t.pair_of == ^pair_of or t.id == ^shared.id)
        )
      end)
    end)

    answers =
      [{a, b}, {b, a}, {a, b}, {b, a}]
      |> Enum.map(fn {by, other} ->
        Task.async(fn -> unboxed(fn -> SharedThreads.pair(server(), by, other) end) end)
      end)
      |> Task.await_many(30_000)

    assert [{:ok, %{id: id}} | _] = answers
    assert Enum.all?(answers, &match?({:ok, %{id: ^id}}, &1))

    unboxed(fn ->
      assert [^id] =
               Arca.Repo.all(from(t in SharedThread, where: t.pair_of == ^pair_of, select: t.id))

      assert Arca.Repo.aggregate(from(m in SharedThreadMember, where: m.thread_id == ^id), :count) ==
               2
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
