# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RestoreChecklistTest do
  @moduledoc """
  The restore checklist (`Sanctum.Pairing.restore_checklist/1`) of a
  person a declared restore found with an API key and a shared entry. A
  restore revokes every share and its owner shares the entry again from
  the Vault page once they have rotated it, so a share is no item of the
  checklist. The checklist stands while a key or webhook of theirs is
  suspended, which only a declared restore does: a person who has
  re-enabled it reads none, whatever else the restore revoked of theirs.
  """

  use ExUnit.Case, async: false

  alias Arca.SecurityTransitions
  alias Sanctum.{Pairing, TestContext}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  defp key!(athanor_id, user_id) do
    now = DateTime.utc_now()
    id = Prima.UUID7.generate_id("key")

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.ApiKey, [
        %{
          id: id,
          name: "key-#{System.unique_integer([:positive])}",
          key_hash: :crypto.strong_rand_bytes(32),
          key_prefix: "cyfr_sk_rs",
          type: "service",
          scope: "[]",
          revoked: false,
          suspended: false,
          created_by: user_id,
          athanor_id: athanor_id,
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  test "lists the suspended key and the entry to rotate, never the share, and stands no " <>
         "longer once the key is re-enabled" do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "local|local|checklist-#{n}", provider: "local"})

    own = Sanctum.Test.People.athanor!(user)
    ctx = %{TestContext.local(:prism) | user_id: user.id, athanor_id: own.id}
    actor = Sanctum.Context.actor(ctx)

    key_id = key!(own.id, user.id)
    entry = Arca.Test.Shares.entry!(actor)
    share = Arca.Test.Shares.share!(actor, entry.id)

    assert {:ok, nil} = Pairing.restore_checklist(ctx)

    {:ok, restore_id} = SecurityTransitions.mark_restore(Prima.Actor.system())

    assert {:ok, %{restore_id: ^restore_id, revoked_share_ids: revoked}} =
             SecurityTransitions.restore(slot: :none)

    assert revoked == [share.id]

    assert {:ok, list} = Pairing.restore_checklist(ctx)
    assert [%{id: ^key_id, athanor_id: athanor_id}] = list.api_keys
    assert athanor_id == own.id
    assert list.webhooks == []
    assert Enum.map(list.vault_entries, & &1.id) == [entry.id]
    assert list.profiles == []
    refute inspect(list) =~ share.id

    # The key re-enabled, nothing a restore alone suspends is left: the
    # checklist stands no longer, though the entry still waits to be
    # rotated and the share stays revoked until it is shared again.
    assert {:ok, _key} =
             Arca.ApiKeyStorage.reenable(actor, user.id, key_id, verify: fn _row -> :ok end)

    assert {:ok, nil} = Pairing.restore_checklist(ctx)
    assert Arca.Test.Shares.share_status(actor, share.id) == "revoked"
  end

  test "a context naming no person reads none" do
    assert {:error, :unauthenticated} =
             Pairing.restore_checklist(%{TestContext.local(:prism) | user_id: nil})
  end
end
