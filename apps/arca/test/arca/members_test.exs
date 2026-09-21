# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.MembersTest do
  @moduledoc """
  The membership rows, and the two shapes the facade has: the roster of
  one athanor, whose id comes from the actor and can name no other, and
  the fabric — a platform grant that names no athanor, a person's seats
  across every athanor, an invitation keyed on an address — which is
  asked for with the platform scope.
  """
  use ExUnit.Case, async: true

  alias Arca.{Athanors, Members}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Cyfr.Actor.system()

  defp in_athanor(id), do: %{Cyfr.Actor.system() | athanor_id: id, scope: :athanor}

  defp group! do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      Athanors.insert(server(), %{
        kind: "group",
        name: "G#{n}",
        slug: "mem-g-#{n}",
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
      nobody = %Cyfr.Actor{athanor_id: nil, user_id: "someone"}

      assert {:error, :no_athanor} = Members.seat(nobody, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(nobody, "usr_1")
      assert {:error, :no_athanor} = Members.find_invited(nobody, "a@example.com")
      assert {:error, :no_athanor} = Members.list(nobody)
      assert {:error, :no_athanor} = Members.count_active(nobody)
      assert {:error, :no_athanor} = Members.count_seats(nobody)
      assert {:error, :no_athanor} = Members.active_user_ids(nobody)
      refute_received :queried

      # The probe is live: an actor with an athanor does query.
      assert {:ok, 0} = Members.count_active(in_athanor("ath_nobody"))
      assert_received :queried
    end

    test "an actor whose athanor is the empty string is refused, not answered emptily" do
      watch_queries!()
      # `""` is an identity that was never resolved, the same thing the
      # layer that establishes identity refuses outright. Taking it would
      # filter on `athanor_id == ""`, match nothing, and answer an empty
      # roster where the refusal belongs.
      unresolved = %{Cyfr.Actor.system() | athanor_id: "", scope: :athanor}

      assert {:error, :no_athanor} = Members.seat(unresolved, %{user_id: "usr_1"})
      assert {:error, :no_athanor} = Members.find(unresolved, "usr_1")
      assert {:error, :no_athanor} = Members.find_invited(unresolved, "a@example.com")
      assert {:error, :no_athanor} = Members.list(unresolved)
      assert {:error, :no_athanor} = Members.count_active(unresolved)
      assert {:error, :no_athanor} = Members.count_seats(unresolved)
      assert {:error, :no_athanor} = Members.active_user_ids(unresolved)
      refute_received :queried
    end

    test "an athanor-scoped actor is refused by every across-tenants function" do
      watch_queries!()
      member = in_athanor("ath_somewhere")
      row = %Arca.Schemas.Membership{id: "mem_x"}

      assert {:error, :cross_tenant} = Members.grant_platform(member, %{user_id: "usr_1"})
      assert {:error, :cross_tenant} = Members.get(member, "mem_x")
      assert {:error, :cross_tenant} = Members.find_platform(member, "usr_1")
      assert {:error, :cross_tenant} = Members.delete(member, row)
      assert {:error, :cross_tenant} = Members.list_platform(member)
      assert {:error, :cross_tenant} = Members.delete_platform(member, "usr_1")
      assert {:error, :cross_tenant} = Members.list_active_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Members.list_all_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Members.delete_all_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Members.shared_estate?(member, "usr_1", "usr_2")

      assert {:error, :cross_tenant} =
               Members.activate_invited(member, "usr_1", "a@example.com", DateTime.utc_now())

      assert {:error, :cross_tenant} =
               Members.withdraw_invites_for_email(member, "a@example.com")

      refute_received :queried
    end

    test "a plain map, or a bare athanor id, raises before any query" do
      watch_queries!()
      athanor = group!()
      drain_queries!()

      # A map carrying an actor's fields is not an actor either.
      map = %{athanor_id: athanor.id, scope: :athanor}
      refused!(:seat, [map, %{user_id: "usr_1"}])
      refused!(:list, [map, []])
      refused!(:count_active, [map])
      refused!(:seat, [athanor.id, %{user_id: "usr_1"}])
      refused!(:list, [athanor.id, []])
      refused!(:count_active, [athanor.id])
      refute_received :queried
    end
  end

  describe "inside one tenant" do
    test "a seat lands in the actor's athanor, whatever athanor the attrs name" do
      a = group!()
      b = group!()
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
      a = group!()
      b = group!()
      here = person_id()
      there = person_id()

      {:ok, _} = Members.seat(in_athanor(a.id), %{user_id: here, added_by: "system"})
      {:ok, _} = Members.seat(in_athanor(b.id), %{user_id: there, added_by: "system"})

      assert {:ok, [%{user_id: ^here}]} = Members.list(in_athanor(a.id))
      assert {:ok, [%{user_id: ^there}]} = Members.list(in_athanor(b.id))
      assert {:ok, 1} = Members.count_active(in_athanor(a.id))
      assert {:ok, %{user_id: ^here}} = Members.find(in_athanor(a.id), here)
      assert {:error, :not_found} = Members.find(in_athanor(a.id), there)
    end

    test "an athanor with no row is :unknown_athanor, and a duplicate is :conflict" do
      athanor = group!()
      user = person_id()

      assert {:error, :unknown_athanor} =
               Members.seat(in_athanor("ath_missing"), %{user_id: user, added_by: "system"})

      assert {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})

      assert {:error, :conflict} =
               Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})
    end

    test "a validation refusal names its fields and carries no changeset" do
      athanor = group!()

      assert {:error, {:invalid, %{scope: [_ | _]}}} =
               Members.seat(in_athanor(athanor.id), %{user_id: person_id(), scope: "superadmin"})
    end

    test "seats count invitations; active members do not" do
      athanor = group!()
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: person_id(), added_by: "x"})

      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{
          email: "invitee@example.com",
          status: "invited",
          added_by: "x"
        })

      assert {:ok, 2} = Members.count_seats(in_athanor(athanor.id))
      assert {:ok, 1} = Members.count_active(in_athanor(athanor.id))

      assert {:ok, %{status: "invited"}} =
               Members.find_invited(in_athanor(athanor.id), "invitee@example.com")
    end
  end

  describe "across tenants" do
    test "a platform grant names no athanor and is read back as the person's" do
      user = person_id()
      assert {:ok, row} = Members.grant_platform(server(), %{user_id: user, added_by: "system"})
      assert row.athanor_id == nil
      assert row.scope == "platform"

      assert {:ok, %{id: id}} = Members.find_platform(server(), user)
      assert id == row.id
      assert {:ok, %{id: ^id}} = Members.get(server(), row.id)
      assert Enum.any?(elem(Members.list_platform(server()), 1), &(&1.id == row.id))

      assert {:ok, 1} = Members.delete_platform(server(), user)
      assert {:error, :not_found} = Members.find_platform(server(), user)
    end

    test "a person's rows are read and swept across every athanor they sat in" do
      a = group!()
      b = group!()
      user = person_id()
      {:ok, _} = Members.seat(in_athanor(a.id), %{user_id: user, added_by: "x"})
      {:ok, _} = Members.seat(in_athanor(b.id), %{user_id: user, added_by: "x"})
      {:ok, _} = Members.grant_platform(server(), %{user_id: user, added_by: "x"})

      assert {:ok, rows} = Members.list_active_for_user(server(), user)
      assert length(rows) == 3
      assert {:ok, all} = Members.list_all_for_user(server(), user)
      assert length(all) == 3

      assert {:ok, true} = shared?(a.id, user)
      assert {:ok, 3} = Members.delete_all_for_user(server(), user)
      assert {:ok, []} = Members.list_all_for_user(server(), user)
    end

    test "two people share an estate only while both seats are active and the estate is" do
      athanor = group!()
      alice = person_id()
      bob = person_id()
      carol = person_id()
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: alice, added_by: "x"})
      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: bob, added_by: "x"})

      assert {:ok, true} = Members.shared_estate?(server(), alice, bob)
      assert {:ok, false} = Members.shared_estate?(server(), alice, carol)

      {:ok, _} = Athanors.update(in_athanor(athanor.id), %{status: "archived"})
      assert {:ok, false} = Members.shared_estate?(server(), alice, bob)
    end
  end

  describe "activate_invited/4" do
    test "claims every invitation the address holds, once" do
      a = group!()
      b = group!()
      user = person_id()
      email = "claim-#{System.unique_integer([:positive])}@example.com"

      for athanor <- [a, b] do
        {:ok, _} =
          Members.seat(in_athanor(athanor.id), %{email: email, status: "invited", added_by: "x"})
      end

      assert {:ok, claimed} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert Enum.sort(claimed) == Enum.sort([a.id, b.id])
      assert {:ok, [^user]} = Members.active_user_ids(in_athanor(a.id))

      # The seat carries no address once it names a person.
      assert {:ok, [%{status: "active", email: nil}]} = Members.list(in_athanor(a.id))

      # A second activation finds nothing, so there is no second membership.
      assert {:ok, []} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert {:ok, 1} = Members.count_active(in_athanor(a.id))
    end

    test "an invitation for an athanor the person already sits in is dropped, not duplicated" do
      athanor = group!()
      user = person_id()
      email = "dup-#{System.unique_integer([:positive])}@example.com"

      {:ok, _} = Members.seat(in_athanor(athanor.id), %{user_id: user, added_by: "x"})

      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{email: email, status: "invited", added_by: "x"})

      assert {:ok, []} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert {:ok, [%{status: "active", user_id: ^user}]} = Members.list(in_athanor(athanor.id))
    end

    test "an invitation already withdrawn claims nothing" do
      athanor = group!()
      user = person_id()
      email = "gone-#{System.unique_integer([:positive])}@example.com"

      {:ok, _} =
        Members.seat(in_athanor(athanor.id), %{email: email, status: "invited", added_by: "x"})

      assert {:ok, [withdrawn]} = Members.withdraw_invites_for_email(server(), email)
      assert withdrawn == athanor.id
      assert {:ok, []} = Members.activate_invited(server(), user, email, DateTime.utc_now())
      assert {:ok, 0} = Members.count_seats(in_athanor(athanor.id))
    end
  end

  defp shared?(athanor_id, user_id) do
    with {:ok, ids} <- Members.active_user_ids(in_athanor(athanor_id)) do
      {:ok, user_id in ids}
    end
  end
end
