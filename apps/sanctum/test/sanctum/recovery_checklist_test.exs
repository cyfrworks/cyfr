# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.RecoveryChecklistTest do
  @moduledoc """
  The restore checklist (`Sanctum.Recovery.checklist/1`) of a person whose
  share a declared restore revoked. A restore revokes every share and its
  owner shares the entry again from the Vault page once they have rotated
  it, so a share is no item of the checklist: a person who has done
  everything the checklist asks reads none, whatever the restore revoked
  of theirs.
  """

  use ExUnit.Case, async: false

  alias Arca.SecurityTransitions
  alias Sanctum.{Recovery, TestContext}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  test "a person whose share the restore revoked reads no checklist once they have " <>
         "re-enabled their passkey and rotated the entry" do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{id: "local|local|checklist-#{n}", provider: "local"})

    own = Sanctum.Test.People.athanor!(user)
    ctx = %{TestContext.local(:prism) | user_id: user.id, athanor_id: own.id}
    actor = Sanctum.Context.actor(ctx)

    # A passkey the restore suspends opens the person's recovery.
    _authenticator = TestContext.passkey!(user.id)
    entry = Arca.Test.Shares.entry!(actor)
    share = Arca.Test.Shares.share!(actor, entry.id)

    {:ok, restore_id} = SecurityTransitions.mark_restore(Prima.Actor.system())

    assert {:ok, %{restore_id: ^restore_id, revoked_share_ids: revoked}} =
             SecurityTransitions.restore(slot: :none)

    assert revoked == [share.id]

    # While they recover, the checklist names the passkey to re-enable and
    # the entry to rotate, and nothing of the share.
    assert {:ok, list} = Recovery.checklist(ctx)
    assert list.restore_id == restore_id
    assert [%{id: passkey_id}] = list.passkeys
    assert Enum.map(list.vault_entries, & &1.id) == [entry.id]
    assert list.profiles == []
    refute inspect(list) =~ share.id

    # Re-enabling the passkey ends the recovery; the entry is rotated.
    assert {:ok, _passkey} =
             Arca.Passkeys.reenable(Prima.Actor.system(), user.id, passkey_id,
               verify: fn _row -> :ok end
             )

    :ok = Arca.VaultStorage.set_status(actor, entry.id, "active")

    # The share stays revoked until it is shared again, and holds no
    # checklist open.
    assert {:ok, nil} = Recovery.checklist(ctx)
    assert Arca.Test.Shares.share_status(actor, share.id) == "revoked"
  end
end
