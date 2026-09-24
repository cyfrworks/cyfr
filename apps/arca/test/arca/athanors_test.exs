# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AthanorsTest do
  @moduledoc """
  The athanor rows, and the two shapes the facade has: the writes that
  take their athanor from the actor and can reach no other, and the
  fabric reads that decide which athanor a caller works in and are asked
  for with the platform scope.
  """
  use ExUnit.Case, async: true

  alias Arca.Athanors

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp server, do: Prima.Actor.system()

  defp in_athanor(id), do: %{Prima.Actor.system() | athanor_id: id, scope: :athanor}

  defp group!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, athanor} =
      Athanors.insert(
        server(),
        Map.merge(
          %{kind: "group", name: "G#{n}", slug: "g-#{n}", created_by: "system"},
          overrides
        )
      )

    athanor
  end

  # Fires only for a query this process ran, so a neighbour's is not
  # mistaken for one the refusal was supposed to prevent.
  defp watch_queries! do
    handler = "athanors-#{System.unique_integer([:positive])}"
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
    assert_raise FunctionClauseError, fn -> apply(Athanors, fun, args) end
  end

  describe "the actor is the first argument, and a wrong one refuses before any query" do
    test "an actor with no athanor is refused by every inside-the-tenant function" do
      watch_queries!()
      nobody = %Prima.Actor{athanor_id: nil, user_id: "someone"}

      assert {:error, :no_athanor} = Athanors.current(nobody)
      assert {:error, :no_athanor} = Athanors.update(nobody, %{name: "X"})
      assert {:error, :no_athanor} = Athanors.set(nobody, name: "X")
      assert {:error, :no_athanor} = Athanors.put_settings(nobody, nil, "{}", DateTime.utc_now())
      refute_received :queried

      # The probe is live: an actor with an athanor does query.
      assert {:error, :not_found} = Athanors.current(in_athanor("ath_nobody"))
      assert_received :queried
    end

    test "an actor whose athanor is the empty string is refused, not answered emptily" do
      watch_queries!()
      # `""` is an identity that was never resolved, the same thing the
      # identity domain above refuses outright. Taking it would filter
      # on `athanor_id == ""`, match nothing, and turn the refusal into an
      # ordinary empty result.
      unresolved = %{Prima.Actor.system() | athanor_id: "", scope: :athanor}

      assert {:error, :no_athanor} = Athanors.current(unresolved)
      assert {:error, :no_athanor} = Athanors.update(unresolved, %{name: "X"})
      assert {:error, :no_athanor} = Athanors.set(unresolved, name: "X")

      assert {:error, :no_athanor} =
               Athanors.put_settings(unresolved, nil, "{}", DateTime.utc_now())

      refute_received :queried
    end

    test "an athanor-scoped actor is refused by every across-tenants function" do
      watch_queries!()
      member = in_athanor("ath_somewhere")

      assert {:error, :cross_tenant} = Athanors.insert(member, %{kind: "group"})
      assert {:error, :cross_tenant} = Athanors.mint(member, attrs: fn -> {:ok, %{}} end)
      assert {:error, :cross_tenant} = Athanors.get(member, "ath_elsewhere")
      assert {:error, :cross_tenant} = Athanors.get_by_owner(member, "usr_1")
      assert {:error, :cross_tenant} = Athanors.get_by_slug(member, "group", "g")
      assert {:error, :cross_tenant} = Athanors.get_by_pair_key(member, "k")
      assert {:error, :cross_tenant} = Athanors.list_by_ids(member, ["ath_elsewhere"])
      assert {:error, :cross_tenant} = Athanors.list_active(member)
      assert {:error, :cross_tenant} = Athanors.list_for_user(member, "usr_1")
      assert {:error, :cross_tenant} = Athanors.count_active(member)
      assert {:error, :cross_tenant} = Athanors.count_groups_created_by(member, "usr_1")
      assert {:error, :cross_tenant} = Athanors.count_pairs_of(member, "usr_1")

      assert {:error, :cross_tenant} =
               Athanors.count_people_created_since(member, DateTime.utc_now())

      refute_received :queried
    end

    test "a map of the actor's fields, or a bare athanor id, raises before any query" do
      watch_queries!()
      athanor = group!()
      drain_queries!()

      # Neither is an actor: a plain map carrying the fields one does, and
      # the bare athanor id a caller might pass in the actor's place.
      tenancy_map = %{athanor_id: athanor.id, scope: :athanor}
      refused!(:current, [tenancy_map])
      refused!(:get, [tenancy_map, athanor.id])
      refused!(:current, [athanor.id])
      refused!(:get, [athanor.id, athanor.id])
      refute_received :queried
    end
  end

  describe "inside one tenant" do
    test "a write takes its athanor from the actor and reaches no other row" do
      a = group!()
      b = group!()

      assert {:ok, %{id: id, name: "renamed"}} =
               Athanors.update(in_athanor(a.id), %{name: "renamed"})

      assert id == a.id
      assert {:ok, %{name: renamed}} = Athanors.current(in_athanor(a.id))
      assert renamed == "renamed"

      # B is untouched: the write could name no athanor but the actor's.
      assert {:ok, %{name: b_name}} = Athanors.current(in_athanor(b.id))
      assert b_name == b.name
    end

    test "a read for one actor cannot return another athanor's row" do
      a = group!()
      b = group!()

      assert {:ok, %{id: a_id}} = Athanors.current(in_athanor(a.id))
      assert a_id == a.id
      refute a_id == b.id
    end

    test "put_settings/4 writes only while the document still reads what the caller saw" do
      athanor = group!()
      now = DateTime.utc_now()

      assert :ok = Athanors.put_settings(in_athanor(athanor.id), nil, ~s({"a":1}), now)
      assert :stale = Athanors.put_settings(in_athanor(athanor.id), nil, ~s({"b":2}), now)

      assert :ok =
               Athanors.put_settings(in_athanor(athanor.id), ~s({"a":1}), ~s({"b":2}), now)

      assert {:ok, %{settings: ~s({"b":2})}} = Athanors.current(in_athanor(athanor.id))
    end

    test "set/2 answers :not_found rather than writing nothing silently" do
      athanor = group!()
      assert :ok = Athanors.set(in_athanor(athanor.id), provisioned_at: DateTime.utc_now())
      assert {:error, :not_found} = Athanors.set(in_athanor("ath_missing"), name: "X")
    end
  end

  describe "insert/2 refusals" do
    test "a slug already taken for the kind is :slug_taken, which a derived slug retries on" do
      athanor = group!()

      assert {:error, :slug_taken} =
               Athanors.insert(server(), %{
                 kind: "group",
                 name: "Other",
                 slug: athanor.slug,
                 created_by: "system"
               })
    end

    test "a validation refusal names its fields and carries no changeset" do
      assert {:error, {:invalid, errors}} =
               Athanors.insert(server(), %{
                 kind: "team",
                 name: "X",
                 slug: "bad slug",
                 created_by: "system"
               })

      assert %{kind: [_ | _], slug: [_ | _]} = errors
      refute match?(%Ecto.Changeset{}, errors)
    end
  end

  describe "mint/2 is one transaction" do
    test "the row, its seats and its guards land together" do
      n = System.unique_integer([:positive])
      creator = "usr_mint_#{n}"

      assert {:ok, athanor} =
               Athanors.mint(server(),
                 hold: [creator],
                 guards: [fn -> :ok end],
                 attrs: fn ->
                   {:ok, %{kind: "group", name: "M#{n}", slug: "m-#{n}", created_by: creator}}
                 end,
                 seats: fn minted ->
                   with {:ok, _} <-
                          Arca.Members.seat(in_athanor(minted.id), %{
                            user_id: creator,
                            scope: "athanor",
                            added_by: creator
                          }),
                        do: :ok
                 end
               )

      assert {:ok, %{status: "active"}} = Athanors.current(in_athanor(athanor.id))
      assert {:ok, [^creator]} = Arca.Members.active_user_ids(in_athanor(athanor.id))
    end

    test "a guard that refuses commits nothing — no athanor row and no membership" do
      n = System.unique_integer([:positive])
      creator = "usr_capped_#{n}"
      slug = "capped-#{n}"

      assert {:error, {:limit_reached, :max_groups_per_person, 1}} =
               Athanors.mint(server(),
                 hold: [creator],
                 guards: [fn -> {:error, {:limit_reached, :max_groups_per_person, 1}} end],
                 attrs: fn ->
                   {:ok, %{kind: "group", name: "C#{n}", slug: slug, created_by: creator}}
                 end,
                 seats: fn minted ->
                   with {:ok, _} <-
                          Arca.Members.seat(in_athanor(minted.id), %{
                            user_id: creator,
                            scope: "athanor",
                            added_by: creator
                          }),
                        do: :ok
                 end
               )

      assert {:error, :not_found} = Athanors.get_by_slug(server(), "group", slug)
      assert {:ok, []} = Athanors.list_for_user(server(), creator)
    end

    test "a seat that refuses takes the athanor row with it" do
      n = System.unique_integer([:positive])
      slug = "seatless-#{n}"

      assert {:error, :nope} =
               Athanors.mint(server(),
                 attrs: fn ->
                   {:ok, %{kind: "group", name: "S#{n}", slug: slug, created_by: "system"}}
                 end,
                 seats: fn _minted -> {:error, :nope} end
               )

      assert {:error, :not_found} = Athanors.get_by_slug(server(), "group", slug)
    end

    test "a slug the index already holds is :slug_taken and nothing is written" do
      athanor = group!()

      assert {:error, :slug_taken} =
               Athanors.mint(server(),
                 attrs: fn ->
                   {:ok, %{kind: "group", name: "Dup", slug: athanor.slug, created_by: "system"}}
                 end
               )
    end
  end

  describe "the fabric reads" do
    test "find an athanor by slug, owner and id; count what the caps bound" do
      n = System.unique_integer([:positive])
      owner = "usr_owner_#{n}"

      {:ok, person} =
        Athanors.insert(server(), %{
          kind: "person",
          name: "P#{n}",
          slug: "p-#{n}",
          owner_user_id: owner,
          created_by: owner
        })

      assert {:ok, %{id: id}} = Athanors.get_by_owner(server(), owner)
      assert id == person.id
      assert {:ok, %{id: ^id}} = Athanors.get_by_slug(server(), "person", person.slug)
      assert {:error, :not_found} = Athanors.get_by_slug(server(), "group", person.slug)
      assert {:ok, %{id: ^id}} = Athanors.get(server(), person.id)
      assert {:error, :not_found} = Athanors.get(server(), "ath_nope")

      assert {:ok, [%{id: ^id}]} = Athanors.list_by_ids(server(), [person.id, "ath_missing"])
      assert {:ok, []} = Athanors.list_by_ids(server(), [])

      assert {:ok, count} = Athanors.count_active(server())
      assert count >= 1

      assert {:ok, 0} = Athanors.count_groups_created_by(server(), owner)
      assert {:ok, 0} = Athanors.count_pairs_of(server(), owner)

      assert {:ok, since} =
               Athanors.count_people_created_since(
                 server(),
                 DateTime.add(DateTime.utc_now(), -3600)
               )

      assert since >= 1
    end
  end
end
