# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PersonIdentitiesTest do
  @moduledoc """
  A person's identity row: one per person, written beside the person row
  inside the mint's own transaction (`also:`), the account they were
  admitted by: its identifier, its directory and the head read, and no
  key; read by the person or the platform, and looked up by identifier
  only by the platform's own actor.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  alias Arca.PersonIdentities

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    hold_slot!()
    :ok
  end

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  # The writes under test are fenced by the member's slot: a claimant runs
  # and this member holds its slot. The process-wide standing and the claim
  # switch are restored after each case.
  defp hold_slot! do
    saved = Map.new(@slot_keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot", 60_000)
    slot
  end

  defp server, do: Prima.Actor.system()

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("g-#{System.unique_integer()}")

  defp person_attrs do
    n = System.unique_integer([:positive])
    now = DateTime.utc_now()

    {%{
       id: Prima.UUID7.generate_id(Prima.PersonId.prefix()),
       provider: "github",
       email: "pid#{n}@example.com",
       email_verified: true,
       first_seen_at: now,
       last_seen_at: now,
       created_at: now,
       updated_at: now
     },
     %{
       key: "github|https://github.com|pid#{n}",
       provider: "github",
       issuer: "https://github.com",
       subject: "pid#{n}",
       first_seen_at: now,
       last_seen_at: now
     }}
  end

  defp account_attrs(user_id) do
    %{
      user_id: user_id,
      provenance: "remote",
      identifier: identifier(),
      directory_url: "https://dir.example",
      head_hash: Prima.Digest.sha256("head-#{System.unique_integer()}")
    }
  end

  defp person! do
    {user, identity} = person_attrs()
    {:ok, person} = Arca.Test.People.mint(server(), user, identity)
    person
  end

  describe "create/2" do
    test "one row per person" do
      person = person!()
      assert {:ok, _} = PersonIdentities.create(server(), account_attrs(person.id))
      assert {:error, :conflict} = PersonIdentities.create(server(), account_attrs(person.id))
    end

    test "an account's row is its identifier, its directory and the head read, and no key" do
      person = person!()
      id = identifier()
      head = Prima.Digest.sha256("head-#{id}")

      account = %{
        user_id: person.id,
        provenance: "remote",
        identifier: id,
        directory_url: "https://dir.example",
        head_hash: head
      }

      assert {:error, {:invalid, %{head_hash: _}}} =
               PersonIdentities.create(server(), Map.delete(account, :head_hash))

      assert {:ok, row} = PersonIdentities.create(server(), account)

      assert row.provenance == "remote"
      assert row.enrollment == "enrolled"
      assert row.head_hash == head
      refute Map.has_key?(row, :live_key_sealed) or Map.has_key?(row, :genesis_hash)
      assert {:ok, %{user_id: user_id}} = PersonIdentities.lookup_identifier(server(), id)
      assert user_id == person.id

      other = person!()

      assert {:error, :conflict} =
               PersonIdentities.create(server(), %{account | user_id: other.id})
    end

    test "only the platform's own actor writes, and only an account's row" do
      person = person!()

      assert {:error, :cross_tenant} =
               PersonIdentities.create(%Prima.Actor{user_id: person.id}, account_attrs(person.id))

      for provenance <- ~w(local door) do
        assert {:error, {:invalid, %{provenance: _}}} =
                 PersonIdentities.create(server(), %{
                   account_attrs(person.id)
                   | provenance: provenance
                 })
      end
    end
  end

  describe "reading" do
    test "a person reads their own row; another person and a tenant actor do not" do
      person = person!()
      {:ok, _} = PersonIdentities.create(server(), account_attrs(person.id))

      assert {:ok, %{user_id: user_id}} =
               PersonIdentities.get(%Prima.Actor{user_id: person.id}, person.id)

      assert user_id == person.id

      assert {:error, :cross_tenant} =
               PersonIdentities.get(%Prima.Actor{user_id: "usr_someone"}, person.id)

      assert {:error, :cross_tenant} =
               PersonIdentities.get(Prima.Actor.in_athanor("ath_test"), person.id)

      assert {:error, :not_found} = PersonIdentities.get(server(), "usr_nobody")
    end

    test "the identifier lookup is the platform's alone" do
      assert {:error, :cross_tenant} =
               PersonIdentities.lookup_identifier(%Prima.Actor{user_id: "usr_x"}, identifier())

      assert {:error, :not_found} = PersonIdentities.lookup_identifier(server(), identifier())
    end
  end

  describe "the first-method mark" do
    test "is set once and never cleared" do
      person = person!()
      {:ok, _} = PersonIdentities.create(server(), account_attrs(person.id))

      assert {:ok, :marked} =
               Arca.Repo.transaction(fn -> PersonIdentities.first_method!(person.id) end)

      assert {:ok, :already} =
               Arca.Repo.transaction(fn -> PersonIdentities.first_method!(person.id) end)

      assert {:ok, :no_identity} =
               Arca.Repo.transaction(fn -> PersonIdentities.first_method!("usr_nobody") end)
    end

    test "reads open before it is set and closed after, open for a person with no row, and only to the person or the platform" do
      person = person!()
      {:ok, _} = PersonIdentities.create(server(), account_attrs(person.id))
      own = %Prima.Actor{user_id: person.id}

      assert {:ok, true} = PersonIdentities.first_method_open?(own, person.id)
      assert {:ok, true} = PersonIdentities.first_method_open?(server(), person.id)

      {:ok, :marked} = Arca.Repo.transaction(fn -> PersonIdentities.first_method!(person.id) end)

      assert {:ok, false} = PersonIdentities.first_method_open?(own, person.id)
      assert {:ok, false} = PersonIdentities.first_method_open?(server(), person.id)

      bare = person!()
      assert {:error, :not_found} = PersonIdentities.get(server(), bare.id)

      assert {:ok, true} =
               PersonIdentities.first_method_open?(%Prima.Actor{user_id: bare.id}, bare.id)

      assert {:error, :cross_tenant} =
               PersonIdentities.first_method_open?(%Prima.Actor{user_id: bare.id}, person.id)

      assert {:error, :cross_tenant} =
               PersonIdentities.first_method_open?(Prima.Actor.in_athanor("ath_test"), person.id)
    end
  end
end
