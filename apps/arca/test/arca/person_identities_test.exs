# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PersonIdentitiesTest do
  @moduledoc """
  A person's identity row: one per person, written beside the person row
  inside the mint's own transaction (`also:`), local with a sealed key set
  and no identifier, or remote with an identifier and no key; read by the
  person or the platform, and looked up by identifier only by the
  platform's own actor.
  """

  # Takes the cell's slot, which is process-wide; each case restores it.
  use ExUnit.Case, async: false

  alias Arca.{PersonIdentities, Users}

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

  defp key, do: :crypto.strong_rand_bytes(32)

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

  defp local_attrs(user_id) do
    %{
      user_id: user_id,
      provenance: "local",
      live_public_key: key(),
      operational_public_key: key(),
      live_key_sealed: "sealed-live",
      operational_key_sealed: "sealed-op"
    }
  end

  defp person! do
    {user, identity} = person_attrs()
    {:ok, person} = Users.mint(server(), user, identity)
    person
  end

  describe "create/2" do
    test "one key set per person" do
      person = person!()
      assert {:ok, _} = PersonIdentities.create(server(), local_attrs(person.id))
      assert {:error, :conflict} = PersonIdentities.create(server(), local_attrs(person.id))
    end

    test "a local row names two distinct keys and their sealed halves, and no identifier" do
      person = person!()
      same = key()

      assert {:error, {:invalid, %{operational_public_key: _}}} =
               PersonIdentities.create(server(), %{
                 local_attrs(person.id)
                 | live_public_key: same,
                   operational_public_key: same
               })

      assert {:error, {:invalid, %{live_key_sealed: _}}} =
               PersonIdentities.create(
                 server(),
                 Map.delete(local_attrs(person.id), :live_key_sealed)
               )

      assert {:error, {:invalid, %{head_hash: _, directory_url: _}}} =
               PersonIdentities.create(
                 server(),
                 Map.put(local_attrs(person.id), :identifier, identifier())
               )

      assert {:error, {:invalid, %{head_hash: _}}} =
               PersonIdentities.create(
                 server(),
                 Map.put(local_attrs(person.id), :head_hash, Prima.Digest.sha256("head"))
               )
    end

    test "a restored local person is written enrolled, with the head its keys belong to" do
      person = person!()
      id = identifier()
      head = Prima.Digest.sha256("recover-entry")

      assert {:ok, row} =
               PersonIdentities.create(
                 server(),
                 Map.merge(local_attrs(person.id), %{
                   identifier: id,
                   head_hash: head,
                   directory_url: "https://dir.example"
                 })
               )

      assert row.enrollment == "enrolled"
      assert row.identifier == id
      assert row.head_hash == head
    end

    test "a remote row names its identifier and directory, and no key" do
      person = person!()
      id = identifier()

      assert {:error, {:invalid, %{live_public_key: _}}} =
               PersonIdentities.create(server(), %{
                 user_id: person.id,
                 provenance: "remote",
                 identifier: id,
                 directory_url: "https://dir.example",
                 live_public_key: key()
               })

      assert {:ok, row} =
               PersonIdentities.create(server(), %{
                 user_id: person.id,
                 provenance: "remote",
                 identifier: id,
                 directory_url: "https://dir.example"
               })

      assert row.provenance == "remote"
      assert row.enrollment == "enrolled"
      assert {:ok, %{user_id: user_id}} = PersonIdentities.lookup_identifier(server(), id)
      assert user_id == person.id

      other = person!()

      assert {:error, :conflict} =
               PersonIdentities.create(server(), %{
                 user_id: other.id,
                 provenance: "remote",
                 identifier: id,
                 directory_url: "https://dir.example"
               })
    end

    test "only the platform's own actor writes, and provenance is closed" do
      person = person!()

      assert {:error, :cross_tenant} =
               PersonIdentities.create(%Prima.Actor{user_id: person.id}, local_attrs(person.id))

      assert {:error, {:invalid, %{provenance: _}}} =
               PersonIdentities.create(server(), %{local_attrs(person.id) | provenance: "door"})
    end
  end

  describe "reading" do
    test "a person reads their own row; another person and a tenant actor do not" do
      person = person!()
      {:ok, _} = PersonIdentities.create(server(), local_attrs(person.id))

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
      {:ok, _} = PersonIdentities.create(server(), local_attrs(person.id))

      assert {:ok, :marked} =
               Arca.Repo.transaction(fn -> PersonIdentities.first_method!(person.id) end)

      assert {:ok, :already} =
               Arca.Repo.transaction(fn -> PersonIdentities.first_method!(person.id) end)

      assert {:ok, :no_identity} =
               Arca.Repo.transaction(fn -> PersonIdentities.first_method!("usr_nobody") end)
    end
  end
end
