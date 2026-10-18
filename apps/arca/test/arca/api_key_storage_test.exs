# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ApiKeyStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ApiKeyStorage

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    actor = Arca.Test.Actor.local()

    {:ok, athanor_id: actor.athanor_id}
  end

  defp key_attrs(name, athanor_id, overrides \\ %{}) do
    hash = :crypto.hash(:sha256, "key_#{name}_#{:rand.uniform(100_000)}")

    Map.merge(
      %{
        name: name,
        key_hash: hash,
        key_prefix: "cyfr_sk_test",
        type: "secret",
        scope: "[]",
        athanor_id: athanor_id,
        created_by: "test_user"
      },
      overrides
    )
  end

  describe "create_key/1 and get_key/2" do
    test "stores and retrieves a key", %{athanor_id: athanor_id} do
      attrs = key_attrs("test-key", athanor_id)
      assert :ok = ApiKeyStorage.create_key(attrs, Arca.Test.Actor.issuance())

      assert {:ok, key} = ApiKeyStorage.get_key(Prima.Actor.in_athanor(athanor_id), "test-key")
      assert key.name == "test-key"
      assert key.type == "secret"
      assert key.revoked == false
    end

    test "returns not_found for missing key", %{athanor_id: athanor_id} do
      assert {:error, :not_found} =
               ApiKeyStorage.get_key(Prima.Actor.in_athanor(athanor_id), "missing")
    end

    test "duplicate name returns already_exists", %{athanor_id: athanor_id} do
      attrs = key_attrs("dup-key", athanor_id)
      :ok = ApiKeyStorage.create_key(attrs, Arca.Test.Actor.issuance())

      assert {:error, :already_exists} =
               ApiKeyStorage.create_key(attrs, Arca.Test.Actor.issuance())
    end
  end

  describe "get_key_by_hash/1" do
    test "retrieves key by hash", %{athanor_id: athanor_id} do
      attrs = key_attrs("hash-key", athanor_id)
      :ok = ApiKeyStorage.create_key(attrs, Arca.Test.Actor.issuance())

      assert {:ok, key} = ApiKeyStorage.get_key_by_hash(attrs.key_hash)
      assert key.name == "hash-key"
    end

    test "returns not_found for unknown hash" do
      unknown_hash = :crypto.hash(:sha256, "unknown_key")
      assert {:error, :not_found} = ApiKeyStorage.get_key_by_hash(unknown_hash)
    end
  end

  describe "list_keys/2" do
    test "lists non-revoked keys", %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("list-a", athanor_id), Arca.Test.Actor.issuance())
      :ok = ApiKeyStorage.create_key(key_attrs("list-b", athanor_id), Arca.Test.Actor.issuance())

      {:ok, keys} = ApiKeyStorage.list_keys(Prima.Actor.in_athanor(athanor_id))
      names = Enum.map(keys, & &1.name)
      assert "list-a" in names
      assert "list-b" in names
    end

    test "returns empty list when no keys" do
      {:ok, keys} = ApiKeyStorage.list_keys(Prima.Actor.in_athanor("ath_empty"))
      assert keys == []
    end
  end

  describe "revoke_key/3" do
    test "revokes a key so it's no longer retrievable", %{athanor_id: athanor_id} do
      :ok =
        ApiKeyStorage.create_key(key_attrs("revoke-me", athanor_id), Arca.Test.Actor.issuance())

      assert :ok = ApiKeyStorage.revoke_key(Prima.Actor.in_athanor(athanor_id), "revoke-me")

      assert {:error, :not_found} =
               ApiKeyStorage.get_key(Prima.Actor.in_athanor(athanor_id), "revoke-me")
    end

    test "returns not_found for missing key", %{athanor_id: athanor_id} do
      assert {:error, :not_found} =
               ApiKeyStorage.revoke_key(Prima.Actor.in_athanor(athanor_id), "nope")
    end

    test "revoked key excluded from list", %{athanor_id: athanor_id} do
      :ok =
        ApiKeyStorage.create_key(key_attrs("revoke-list", athanor_id), Arca.Test.Actor.issuance())

      :ok = ApiKeyStorage.revoke_key(Prima.Actor.in_athanor(athanor_id), "revoke-list")

      {:ok, keys} = ApiKeyStorage.list_keys(Prima.Actor.in_athanor(athanor_id))
      refute Enum.any?(keys, &(&1.name == "revoke-list"))
    end
  end

  describe "rotate_key/5" do
    test "updates hash and prefix", %{athanor_id: athanor_id} do
      :ok =
        ApiKeyStorage.create_key(key_attrs("rotate-me", athanor_id), Arca.Test.Actor.issuance())

      new_hash = :crypto.hash(:sha256, "rotated_key")
      new_prefix = "cyfr_sk_rotated"

      assert :ok =
               ApiKeyStorage.rotate_key(
                 Prima.Actor.in_athanor(athanor_id),
                 "rotate-me",
                 new_hash,
                 new_prefix,
                 Arca.Test.Actor.issuance()
               )

      {:ok, key} = ApiKeyStorage.get_key_by_hash(new_hash)
      assert key.name == "rotate-me"
      assert key.key_prefix == new_prefix
    end

    test "returns not_found for missing key", %{athanor_id: athanor_id} do
      new_hash = :crypto.hash(:sha256, "nope")

      assert {:error, :not_found} =
               ApiKeyStorage.rotate_key(
                 Prima.Actor.in_athanor(athanor_id),
                 "nope",
                 new_hash,
                 "pfx",
                 Arca.Test.Actor.issuance()
               )
    end
  end

  describe "tenant isolation" do
    test "different athanors cannot see each other's keys" do
      :ok =
        ApiKeyStorage.create_key(
          key_attrs("shared-name", "ath_alpha"),
          Arca.Test.Actor.issuance()
        )

      :ok =
        ApiKeyStorage.create_key(key_attrs("shared-name", "ath_beta"), Arca.Test.Actor.issuance())

      {:ok, key_a} = ApiKeyStorage.get_key(Prima.Actor.in_athanor("ath_alpha"), "shared-name")
      {:ok, key_b} = ApiKeyStorage.get_key(Prima.Actor.in_athanor("ath_beta"), "shared-name")
      assert key_a.athanor_id != key_b.athanor_id

      {:ok, a_keys} = ApiKeyStorage.list_keys(Prima.Actor.in_athanor("ath_alpha"))
      {:ok, b_keys} = ApiKeyStorage.list_keys(Prima.Actor.in_athanor("ath_beta"))
      assert length(a_keys) == 1
      assert length(b_keys) == 1
    end

    # NOTE: there is no tenant-scoped hash lookup. API keys are athanor
    # credentials: a key is resolved by its globally-unique hash and its
    # athanor is read back from the row; the tenant binding is then enforced
    # on the context the identity domain builds from it and by
    # `Arca.QueryHelpers.where_tenant/2` on the reads that follow (covered by
    # Arca.AthanorLessFailClosedTest and that domain's API key tests), not
    # by a tenant-scoped storage lookup.
  end

  # A declared restore suspends every unrevoked key; these put a key in
  # that state the way the transition leaves it.
  defp suspend!(athanor_id, name) do
    import Ecto.Query

    {1, _} =
      from(k in Arca.Schemas.ApiKey,
        where: k.athanor_id == ^athanor_id and k.name == ^name and k.revoked == false
      )
      |> Arca.Repo.update_all(set: [suspended: true])

    {:ok, key} = ApiKeyStorage.get_key(Prima.Actor.in_athanor(athanor_id), name)
    key
  end

  defp stored(id), do: Arca.Repo.get!(Arca.Schemas.ApiKey, id)

  describe "a suspended key" do
    test "is read with its flag, and is not the key a key-authenticated context reads", %{
      athanor_id: athanor_id
    } do
      attrs = key_attrs("held", athanor_id)
      :ok = ApiKeyStorage.create_key(attrs, Arca.Test.Actor.issuance())
      actor = Prima.Actor.in_athanor(athanor_id)
      key = suspend!(athanor_id, "held")

      assert key.suspended == true
      assert {:ok, %{suspended: true}} = ApiKeyStorage.get_key_by_hash(attrs.key_hash)
      assert {:ok, [%{name: "held", suspended: true}]} = ApiKeyStorage.list_keys(actor)
      assert {:error, :not_found} = ApiKeyStorage.get_key_by_id(actor, key.id)
    end

    test "is not rotated, so no successor stands unsuspended", %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("held", athanor_id), Arca.Test.Actor.issuance())
      key = suspend!(athanor_id, "held")
      new_hash = :crypto.hash(:sha256, "successor")

      assert {:error, :suspended} =
               ApiKeyStorage.rotate_key(
                 Prima.Actor.in_athanor(athanor_id),
                 "held",
                 new_hash,
                 "pfx",
                 Arca.Test.Actor.issuance()
               )

      assert {:error, :not_found} = ApiKeyStorage.get_key_by_hash(new_hash)
      assert %{suspended: true, revoked: false} = stored(key.id)
    end
  end

  describe "reenable/4" do
    setup %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("held", athanor_id), Arca.Test.Actor.issuance())
      %{key: suspend!(athanor_id, "held"), actor: Prima.Actor.in_athanor(athanor_id)}
    end

    test "writes the person's suspended key back after verify agrees, with the row it saw", %{
      key: key,
      actor: actor
    } do
      parent = self()

      verify = fn row ->
        send(parent, {:verified, row})
        :ok
      end

      assert {:ok, reenabled} = ApiKeyStorage.reenable(actor, "test_user", key.id, verify: verify)
      assert %{id: id, suspended: false, revoked: false} = reenabled
      assert id == key.id
      refute Map.has_key?(reenabled, :key_hash)

      assert_received {:verified, %{id: ^id, suspended: true} = seen}
      refute Map.has_key?(seen, :key_hash)

      assert %{suspended: false, revoked: false} = stored(key.id)
      assert {:ok, %{id: ^id}} = ApiKeyStorage.get_key_by_id(actor, key.id)
    end

    test "a verify refusal rolls back and is the answer", %{key: key, actor: actor} do
      assert {:error, :not_standing} =
               ApiKeyStorage.reenable(actor, "test_user", key.id,
                 verify: fn _ -> {:error, :not_standing} end
               )

      assert {:error, :refused} =
               ApiKeyStorage.reenable(actor, "test_user", key.id, verify: fn _ -> :refused end)

      assert %{suspended: true} = stored(key.id)
    end

    test "another person's key, another athanor's or an unknown id is not found", %{
      key: key,
      actor: actor
    } do
      never = fn _ -> flunk("verify asked for a key that is not the person's") end

      assert {:error, :not_found} =
               ApiKeyStorage.reenable(actor, "someone_else", key.id, verify: never)

      assert {:error, :not_found} =
               ApiKeyStorage.reenable(Prima.Actor.in_athanor("ath_other"), "test_user", key.id,
                 verify: never
               )

      assert {:error, :not_found} =
               ApiKeyStorage.reenable(actor, "test_user", "key_unknown", verify: never)

      assert {:error, :no_athanor} =
               ApiKeyStorage.reenable(Prima.Actor.system(), "test_user", key.id, verify: never)

      assert %{suspended: true} = stored(key.id)
    end

    test "a revoked key is never revived, and a standing one is not suspended", %{
      athanor_id: athanor_id,
      key: key,
      actor: actor
    } do
      never = fn _ -> flunk("verify asked for a key that cannot be re-enabled") end
      :ok = ApiKeyStorage.revoke_key(actor, "held")

      assert {:error, :revoked} =
               ApiKeyStorage.reenable(actor, "test_user", key.id, verify: never)

      assert %{revoked: true} = stored(key.id)

      :ok = ApiKeyStorage.create_key(key_attrs("live", athanor_id), Arca.Test.Actor.issuance())
      {:ok, live} = ApiKeyStorage.get_key(actor, "live")

      assert {:error, :not_suspended} =
               ApiKeyStorage.reenable(actor, "test_user", live.id, verify: never)
    end
  end

  describe "get_created_key/3" do
    test "reads the person's own key in any state, and no one else's", %{athanor_id: athanor_id} do
      :ok = ApiKeyStorage.create_key(key_attrs("mine", athanor_id), Arca.Test.Actor.issuance())
      actor = Prima.Actor.in_athanor(athanor_id)
      {:ok, key} = ApiKeyStorage.get_key(actor, "mine")
      :ok = ApiKeyStorage.revoke_key(actor, "mine")

      assert {:ok, %{id: id, revoked: true, suspended: false}} =
               ApiKeyStorage.get_created_key(actor, "test_user", key.id)

      assert id == key.id
      assert {:error, :not_found} = ApiKeyStorage.get_created_key(actor, "other", key.id)

      assert {:error, :not_found} =
               ApiKeyStorage.get_created_key(Prima.Actor.in_athanor("ath_x"), "test_user", key.id)
    end
  end
end
