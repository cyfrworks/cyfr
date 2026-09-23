# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.PairsTest do
  # A DM is a frozen group estate: two people, a closed door, and
  # everything an athanor already knows how to be. These are the rules that
  # make "click a name" safe to do twice, and safe to do again after
  # somebody leaves.
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.{Athanors, Members, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    n = System.unique_integer([:positive])
    {:ok, alice: person("alice-#{n}"), bob: person("bob-#{n}"), carol: person("carol-#{n}")}
  end

  defp person(handle) do
    id = "github|https://github.com|#{handle}"

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: id,
        provider: "github",
        email: "#{handle}@example.com",
        verified: true
      })

    user.id
  end

  describe "create_pair/2" do
    test "mints a frozen two-person estate", %{alice: alice, bob: bob} do
      assert {:ok, pair} = Athanors.create_pair(alice, bob)

      assert pair.kind == "group"
      assert pair.roster == "frozen"
      assert is_binary(pair.pair_key)
      assert Members.member?(alice, pair.id)
      assert Members.member?(bob, pair.id)
    end

    test "finds the existing pair rather than minting a second", %{alice: alice, bob: bob} do
      {:ok, first} = Athanors.create_pair(alice, bob)

      # Both orders name the same estate: the key is order-independent, so
      # Bob clicking Alice lands where Alice clicking Bob did.
      assert {:ok, ^first} = Athanors.create_pair(alice, bob)
      assert {:ok, second} = Athanors.create_pair(bob, alice)
      assert second.id == first.id
    end

    test "a concurrent double-click still yields one estate", %{alice: alice, bob: bob} do
      # The unique index is the arbiter; the loser reads the winner's row
      # instead of reporting a conflict at a person who clicked twice.
      results =
        1..6
        |> Task.async_stream(fn _ -> Athanors.create_pair(alice, bob) end,
          max_concurrency: 6,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      ids = results |> Enum.map(fn {:ok, a} -> a.id end) |> Enum.uniq()
      assert length(ids) == 1
    end

    test "is a row only — filling it is first need", %{alice: alice, bob: bob} do
      # Opening a chat must not wait on a registry round trip that can
      # fail. `Sanctum.Provisioning.start_provisioning/1` fills it when
      # something first reads its bundle.
      assert {:ok, pair} = Athanors.create_pair(alice, bob)
      refute pair.provisioned_at
    end

    test "refuses a pair of one person", %{alice: alice} do
      assert {:error, :invalid_pair} = Athanors.create_pair(alice, alice)
    end
  end

  describe "pair_key/2" do
    test "is order-independent and names exactly two people" do
      assert Athanors.pair_key("a", "b") == Athanors.pair_key(["b", "a"], nil)

      # A key over one id, or three, would name nothing a pair can be.
      assert_raise FunctionClauseError, fn -> Athanors.pair_key(["a"], nil) end
      assert_raise FunctionClauseError, fn -> Athanors.pair_key(["a", "b", "c"], nil) end
    end

    test "delimits the ids by encoding, not by a separator an id could hold" do
      # Under a newline join these two pairs hashed the same bytes.
      refute Athanors.pair_key("a\nb", "c") == Athanors.pair_key("a", "b\nc")
    end
  end

  describe "the door is closed" do
    test "every writer of a membership row refuses a frozen estate, not only add/3", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, pair} = Athanors.create_pair(alice, bob)

      assert {:error, :frozen_roster} =
               Members.create(%{user_id: carol, scope: "athanor", athanor_id: pair.id})

      assert {:error, :frozen_roster} =
               Members.ensure(carol, scope: "athanor", athanor_id: pair.id)

      {:ok, rows} = Members.list_by_athanor(pair.id)
      assert length(rows) == 2
    end

    test "member.add refuses a frozen estate on both arms", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, pair} = Athanors.create_pair(alice, bob)

      # Guarded as a head clause beside the person guard, so an invitation
      # by email cannot walk around a rule enforced only on user ids.
      assert {:error, :frozen_roster} = Members.add(pair, [user_id: carol], alice)

      assert {:error, :frozen_roster} =
               Members.add(pair, [email: "carol-elsewhere@example.com"], alice)

      refute Members.member?(carol, pair.id)
    end

    test "adding a third person is a NEW open estate; the pair stands", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, pair} = Athanors.create_pair(alice, bob)

      {:ok, trio} = Athanors.create_group(alice, "Trip")
      {:ok, :added} = Members.add(trio, [user_id: bob], alice)
      {:ok, :added} = Members.add(trio, [user_id: carol], alice)

      assert trio.id != pair.id
      assert trio.roster == "open"

      # History is never copied, and the two-person tape is still there.
      {:ok, still} = Athanors.get(pair.id)
      assert still.status == "active"
    end
  end

  describe "leaving" do
    test "a frozen estate ends when ANYONE leaves, not when it empties", %{
      alice: alice,
      bob: bob
    } do
      {:ok, pair} = Athanors.create_pair(alice, bob)
      :ok = Members.remove_member(pair, user_id: alice)

      # Not "one member left standing": a one-person frozen estate would be
      # a second You that Bob could still open, and its key would still
      # hash both ids.
      {:ok, archived} = Athanors.get(pair.id)
      assert archived.status == "archived"
    end

    test "a leave that cannot end the pair reports failure and stays retryable", %{
      alice: alice,
      bob: bob
    } do
      {:ok, pair} = Athanors.create_pair(alice, bob)

      # Make the archive itself refuse: its re-read finds a shape the
      # guard rejects. The trigger is contrived; the ORDER is the point —
      # the membership row must survive a failed archive, because with the
      # row gone a retry finds nothing and the husk's pair_key would stand
      # forever.
      row = Arca.Repo.get!(Arca.Schemas.Athanor, pair.id)
      {:ok, _} = row |> Ecto.Changeset.change(kind: "person") |> Arca.Repo.update()

      assert {:error, :person_athanor_cannot_be_archived} =
               Members.remove_member(pair, user_id: alice)

      assert Members.member?(alice, pair.id)

      row = Arca.Repo.get!(Arca.Schemas.Athanor, pair.id)
      {:ok, _} = row |> Ecto.Changeset.change(kind: "group") |> Arca.Repo.update()

      # The retry goes clean through: the tape ends and the key is
      # released for a new one.
      :ok = Members.remove_member(pair, user_id: alice)
      {:ok, archived} = Athanors.get(pair.id)
      assert archived.status == "archived"
      assert {:ok, second} = Athanors.create_pair(alice, bob)
      assert second.id != pair.id
    end

    test "clicking again after a departure mints a NEW tape", %{alice: alice, bob: bob} do
      {:ok, first} = Athanors.create_pair(alice, bob)
      :ok = Members.remove_member(first, user_id: alice)

      # The husk holds one member — Bob. Reopened, it would seat him alone
      # in a second You, so an ended DM is final on every path, including
      # the verb that reopens any other archived estate.
      {:ok, husk} = Athanors.get(first.id)
      assert husk.status == "archived"
      assert {:error, :frozen_is_final} = Athanors.unarchive(husk)
      assert {:error, :frozen_is_final} = Athanors.unarchive(first)
      assert {:ok, %{status: "archived"}} = Athanors.get(first.id)

      # The unique index is partial on ACTIVE precisely so the archived
      # husk does not hold the key hostage — without that, these two could
      # never be paired again.
      assert {:ok, second} = Athanors.create_pair(alice, bob)
      assert second.id != first.id
      assert second.status == "active"

      # And the old tape is not reopened.
      {:ok, old} = Athanors.get(first.id)
      assert old.status == "archived"
    end
  end

  describe "caps" do
    test "a pair does not count against the per-person group cap", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      original = Application.get_env(:sanctum, :caps, [])
      Application.put_env(:sanctum, :caps, Keyword.put(original, :max_groups_per_person, 1))
      on_exit(fn -> Application.put_env(:sanctum, :caps, original) end)

      # `CYFR_MAX_GROUPS_PER_PERSON` bounds groups a person deliberately
      # made. Counting DMs would turn it into "how many people may you
      # talk to", which is not what an operator setting it means.
      {:ok, _} = Athanors.create_pair(alice, bob)
      {:ok, _} = Athanors.create_pair(alice, carol)

      assert {:ok, _} = Athanors.create_group(alice, "My one group")

      assert {:error, {:limit_reached, :max_groups_per_person, 1}} =
               Athanors.create_group(alice, "One too many")
    end

    test "a person at the pair cap cannot open another DM — from either side", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      original = Application.get_env(:sanctum, :caps, [])
      Application.put_env(:sanctum, :caps, Keyword.put(original, :max_pairs_per_person, 1))
      on_exit(fn -> Application.put_env(:sanctum, :caps, original) end)

      {:ok, pair} = Athanors.create_pair(alice, bob)

      # Alice holds her one DM. A pair is minted for two, so Carol — who
      # holds none — cannot reach Alice either: one member of a large room
      # must not be able to mint an estate per co-member, nor have one
      # minted onto them.
      assert {:error, {:limit_reached, :max_pairs_per_person, 1}} =
               Athanors.create_pair(alice, carol)

      assert {:error, {:limit_reached, :max_pairs_per_person, 1}} =
               Athanors.create_pair(carol, alice)

      refute Enum.any?(Athanors.list_for_user(carol), &(&1.roster == "frozen"))

      # Finding the DM that exists is not a mint, and is never capped.
      assert {:ok, ^pair} = Athanors.create_pair(bob, alice)
    end

    test "two DMs minted at once cannot both pass the cap", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      original = Application.get_env(:sanctum, :caps, [])
      Application.put_env(:sanctum, :caps, Keyword.put(original, :max_pairs_per_person, 1))
      on_exit(fn -> Application.put_env(:sanctum, :caps, original) end)

      results =
        [bob, carol]
        |> Task.async_stream(&Athanors.create_pair(alice, &1),
          max_concurrency: 2,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert [{:error, {:limit_reached, :max_pairs_per_person, 1}}, {:ok, _}] =
               Enum.sort_by(results, &elem(&1, 0))

      assert Enum.count(Athanors.list_for_user(alice), &(&1.roster == "frozen")) == 1
    end

    test "an ended DM frees its place under the pair cap", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      original = Application.get_env(:sanctum, :caps, [])
      Application.put_env(:sanctum, :caps, Keyword.put(original, :max_pairs_per_person, 1))
      on_exit(fn -> Application.put_env(:sanctum, :caps, original) end)

      {:ok, pair} = Athanors.create_pair(alice, bob)

      assert {:error, {:limit_reached, :max_pairs_per_person, 1}} =
               Athanors.create_pair(alice, carol)

      # Bob leaves; the tape is archived, and archived is not counted.
      :ok = Members.remove_member(pair, user_id: bob)
      assert {:ok, next} = Athanors.create_pair(alice, carol)
      assert next.roster == "frozen"
    end
  end
end
