# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.MembersTest do
  @moduledoc """
  The membership rows, and the two shapes the facade has: the roster of
  one athanor, whose id comes from the actor and can name no other, and
  the fabric — a platform grant that names no athanor and a person's
  rows across every athanor — which is asked for with the platform scope.
  """
  use ExUnit.Case, async: true

  alias Arca.{Athanors, Members}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()

  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  defp athanor! do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      Athanors.insert(server(), %{
        name: "A#{n}",
        slug: "mem-a-#{n}",
        owner_user_id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
        created_by: "system"
      })

    athanor
  end

  defp person_id, do: "usr_#{System.unique_integer([:positive])}"

  defp watch_queries! do
    handler = "members-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measure, _meta, _config -> if self() == parent, do: send(parent, :queried) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Every query this process has run so far, forgotten: what the refusals
  # below must not produce is a query of their own.
  defp drain_queries! do
    receive do
      :queried -> drain_queries!()
    after
      0 -> :ok
    end
  end

  # Called through `apply/3`: the refusal under test is the one a caller
  # makes at run time, and a literal call the compiler can type-check
  # would be refused before this file ever runs.
  defp refused!(fun, args) do
    assert_raise FunctionClauseError, fn -> apply(Members, fun, args) end
  end

  describe "the actor is the first argument, and a wrong one refuses before any query" do
    test "an actor with no athanor is refused by every inside-the-tenant function" do
      watch_queries!()
      nobody = %Prima.Actor{athanor_id: nil, user_id: "someone"}

      assert {:error, :no_athanor} = Members.seat(nobody, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(nobody, "usr_1")
      assert {:error, :no_athanor} = Members.list(nobody)
      assert {:error, :no_athanor} = Members.active_user_ids(nobody)
      refute_received :queried

      # The probe is live: an actor with an athanor does query.
      assert {:ok, []} = Members.active_user_ids(in_athanor("ath_nobody"))
      assert_received :queried
    end

    test "an actor whose athanor is the empty string is refused, not answered emptily" do
      watch_queries!()
      # `""` is an identity that was never resolved, the same thing the
      # layer that establishes identity refuses outright. Taking it would
      # filter on `athanor_id == ""`, match nothing, and answer an empty
      # roster where the refusal belongs.
      unresolved = %{Prima.Actor.system() | athanor_id: "", scope: :athanor}

      assert {:error, :no_athanor} = Members.seat(unresolved, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(unresolved, "usr_1")
      assert {:error, :no_athanor} = Members.list(unresolved)
      assert {:error, :no_athanor} = Members.active_user_ids(unresolved)
      refute_received :queried
    end

    test "an athanor-scoped actor is refused by every across-tenants function" do
      watch_queries!()
      member = in_athanor("ath_somewhere")

      assert {:error, :cross_tenant} = Members.get(member, "mem_x")
      assert {:error, :cross_tenant} = Members.find_platform(member, "usr_1")
      assert {:error, :cross_tenant} = Members.list_platform(member)
      assert {:error, :cross_tenant} = Members.list_active_for_user(member, "usr_1")

      refute_received :queried
    end

    test "a plain map, or a bare athanor id, raises before any query" do
      watch_queries!()
      athanor = athanor!()
      drain_queries!()

      # A map carrying an actor's fields is not an actor either.
      map = %{athanor_id: athanor.id, scope: :athanor}
      refused!(:seat, [map, %{user_id: "usr_1"}])
      refused!(:list, [map, []])
      refused!(:active_user_ids, [map])
      refused!(:seat, [athanor.id, %{user_id: "usr_1"}])
      refused!(:list, [athanor.id, []])
      refused!(:active_user_ids, [athanor.id])
      refute_received :queried
    end
  end

  describe "inside one tenant" do
    test "a seat lands in the actor's athanor, whatever athanor the attrs name" do
      a = athanor!()
      b = athanor!()
      user = person_id()

      assert {:ok, row} =
               Members.seat(in_athanor(a.id), %{
                 user_id: user,
                 scope: "athanor",
                 athanor_id: b.id,
                 added_by: "system"
               })

      assert row.athanor_id == a.id
      assert {:ok, [^user]} = Members.active_user_ids(in_athanor(a.id))
      assert {:ok, []} = Members.active_user_ids(in_athanor(b.id))
    end

    test "a read for one actor cannot return another athanor's rows" do
      a = athanor!()
      b = athanor!()
      here = person_id()
      there = person_id()

      {:ok, _} = Members.seat(in_athanor(a.id), %{user_id: here, added_by: "system"})
      {:ok, _} = Members.seat(in_athanor(b.id), %{user_id: there, added_by: "system"})

      assert {:ok, [%{user_id: ^here}]} = Members.list(in_athanor(a.id))
      assert {:ok, [%{user_id: ^there}]} = Members.list(in_athanor(b.id))
      assert {:ok, [^here]} = Members.active_user_ids(in_athanor(a.id))
      assert {:ok, %{user_id: ^here}} = Members.find(in_athanor(a.id), here)
      assert {:error, :not_found} = Members.find(in_athanor(a.id), there)
    end

    test "an athanor with no row is :unknown_athanor, and a duplicate is :conflict" do
      athanor = athanor!()
      user = person_id()

      assert {:error, :unknown_athanor} =
               Members.seat(in_athanor("ath_missing"), %{user_id: user, added_by: "system"})

      assert {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})

      assert {:error, :conflict} =
               Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})
    end

    test "a validation refusal names its fields and carries no changeset" do
      athanor = athanor!()

      assert {:error, {:invalid, %{scope: [_ | _]}}} =
               Members.seat(in_athanor(athanor.id), %{user_id: person_id(), scope: "superadmin"})
    end

    test "a seat in an archived athanor is :athanor_archived and writes nothing" do
      archived = athanor!()

      {:ok, _} =
        Arca.SecurityTransitions.archive_athanor(server(), archived.id, verify: fn _ -> :ok end)

      user = person_id()

      assert {:error, :athanor_archived} =
               Members.seat(in_athanor(archived.id), %{user_id: user, added_by: "x"})

      assert {:error, :not_found} = Members.find(in_athanor(archived.id), user)
    end
  end

  describe "across tenants" do
    test "the platform grant, written inside a transaction, names no athanor and is read back as the person's" do
      user = person_id()
      assert {:ok, :ok} = Arca.Repo.transaction(fn -> Members.grant_platform!(user) end)

      assert {:ok, row} = Members.find_platform(server(), user)
      assert row.athanor_id == nil
      assert row.scope == "platform"
      assert {:ok, %{id: id}} = Members.get(server(), row.id)
      assert id == row.id
      assert Enum.any?(elem(Members.list_platform(server()), 1), &(&1.id == row.id))
    end

    test "a person's active rows are read across tenants, their seat and their grant alike" do
      a = athanor!()
      user = person_id()
      {:ok, _} = Members.seat(in_athanor(a.id), %{user_id: user, added_by: "x"})
      _grant = grant!(user)

      assert {:ok, rows} = Members.list_active_for_user(server(), user)

      assert rows |> Enum.map(&{&1.scope, &1.athanor_id}) |> Enum.sort() ==
               [{"athanor", a.id}, {"platform", nil}]

      assert {:ok, true} = shared?(a.id, user)
    end
  end

  # The platform row for `user_id`, as the first person's mint writes it.
  defp grant!(user_id) do
    {:ok, :ok} = Arca.Repo.transaction(fn -> Members.grant_platform!(user_id) end)
    {:ok, grant} = Members.find_platform(server(), user_id)
    grant
  end

  defp shared?(athanor_id, user_id) do
    with {:ok, ids} <- Members.active_user_ids(in_athanor(athanor_id)) do
      {:ok, user_id in ids}
    end
  end
end

defmodule Arca.MembersLockTest do
  @moduledoc """
  The membership writers under two real connections, outside the
  sandbox. Every writer of a row naming a person — a seat, the platform
  grant — takes the person's lock first, so none overtakes a denial
  holding them: on PostgreSQL by waiting on the row, on SQLite by waiting
  at the lock its transaction takes at entry.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.Members
  alias Arca.Schemas.{Athanor, ExternalIdentity, Membership, User}
  alias Ecto.Adapters.SQL.Sandbox

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
  defp server, do: Prima.Actor.system()

  setup do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id(Prima.PersonId.prefix())

    {:ok, user} =
      unboxed(fn ->
        Arca.Test.People.mint(
          server(),
          %{
            id: id,
            email: "lock#{n}@example.com",
            email_verified: true,
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          },
          %{
            key: "github|https://github.com|lock#{n}",
            provider: "github",
            issuer: "https://github.com",
            subject: "lock#{n}",
            first_seen_at: now,
            last_seen_at: now
          }
        )
      end)

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(where(Membership, user_id: ^id))
        Arca.Repo.delete_all(where(ExternalIdentity, user_id: ^id))
        Arca.Repo.delete_all(where(User, id: ^id))
      end)
    end)

    {:ok, user: user}
  end

  test "a seat and the grant each wait for whoever holds the person", %{user: user} do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      unboxed(fn ->
        Arca.Athanors.insert(server(), %{
          name: "L#{n}",
          slug: "mem-lock-#{n}",
          owner_user_id: user.id,
          created_by: "system"
        })
      end)

    seated = athanor.id

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(m in Membership, where: m.athanor_id == ^seated))
        Arca.Repo.delete_all(from(a in Athanor, where: a.id == ^seated))
      end)
    end)

    writers = [
      seat: fn -> Members.seat(in_athanor(seated), %{user_id: user.id, added_by: "x"}) end,
      grant: fn -> Arca.Repo.transaction(fn -> Members.grant_platform!(user.id) end) end
    ]

    for {name, write} <- writers do
      holder = hold_person(user.id)
      writer = Task.async(fn -> unboxed(write) end)
      refute Task.yield(writer, 300), "#{name} was written while the person was held"
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 25_000)
      assert {:ok, _} = Task.await(writer, 25_000), "#{name}"
    end

    unboxed(fn ->
      seats =
        Arca.Repo.all(from(m in Membership, where: m.user_id == ^user.id, select: m.athanor_id))

      assert Enum.sort(seats) == Enum.sort([nil, seated])
    end)
  end

  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  # A transaction holding the person's row, as a denial holds it
  # (`Arca.SecurityTransitions`), until the test says release.
  defp hold_person(user_id) do
    test = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(u in User, where: u.id == ^user_id)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one()

            send(test, :person_held)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :person_held, 5_000
    holder
  end
end
