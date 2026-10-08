# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaFingerprintTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  require Arca.Repo.Errors

  alias Arca.SchemaFingerprint
  alias Arca.Schemas.ServerMeta

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  test "the baseline records the fingerprint of the migrations this release carries" do
    assert {:ok, SchemaFingerprint.current()} ==
             Arca.ServerMetaStorage.get(SchemaFingerprint.key())

    assert :ok = SchemaFingerprint.verify()
  end

  test "a database built from a different schema is refused, naming the recreate" do
    {1, _} = Arca.Repo.update_all(fingerprint_row(), set: [value: "an-older-schema"])

    assert {:error, message} = SchemaFingerprint.verify()
    assert message =~ "was built from a different schema (an-older-schema)"
    assert message =~ "There is no upgrade path"
    assert_raise RuntimeError, ~r/different schema/, fn -> SchemaFingerprint.verify!() end
  end

  test "the boot step refuses a database built from a different schema" do
    assert :ignore = SchemaFingerprint.Check.init([])

    {1, _} = Arca.Repo.update_all(fingerprint_row(), set: [value: "an-older-schema"])
    assert_raise RuntimeError, ~r/different schema/, fn -> SchemaFingerprint.Check.init([]) end
  end

  test "a database that records no fingerprint is refused" do
    {1, _} = Arca.Repo.delete_all(fingerprint_row())

    assert {:error, message} = SchemaFingerprint.verify()
    assert message =~ "records no schema fingerprint"
  end

  test "the storage projection tables are the fingerprinted baseline's, with their constraints" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    source = File.read!(baseline)

    for table <- ~w(storage_projection_roots storage_projection_changes) do
      assert source =~ "create table(:#{table}", "#{table} is not in the baseline"
      assert table in Arca.TenantTables.roster()
    end

    athanor = "ath_fingerprint_#{System.unique_integer([:positive])}"

    root = %{
      id: "spr_1",
      athanor_id: athanor,
      root: "components",
      epoch: 1,
      acknowledged_epoch: 0
    }

    # One root row per athanor and root, and an epoch that is a generation.
    assert :ok = insert_row("storage_projection_roots", root)
    assert :refused = insert_row("storage_projection_roots", %{root | id: "spr_2"})

    assert :refused =
             insert_row("storage_projection_roots", %{root | id: "spr_3", root: "aqua", epoch: 0})

    assert :refused =
             insert_row("storage_projection_roots", %{
               root
               | id: "spr_4",
                 athanor_id: athanor <> "_b",
                 acknowledged_epoch: -1
             })

    now = DateTime.utc_now()

    change = %{
      id: "spc_1",
      athanor_id: athanor,
      root: "components",
      unit_key: "catalysts/local/a/1.0.0",
      generation: 2,
      inserted_at: now,
      updated_at: now
    }

    # One change row per unit, and no unit row it could reference.
    assert :ok = insert_row("storage_projection_changes", change)
    assert :refused = insert_row("storage_projection_changes", %{change | id: "spc_2"})
    assert :ok = insert_row("storage_projection_changes", %{change | id: "spc_3", root: "aqua"})
  end

  test "the retention settings table is the fingerprinted baseline's, with its constraints" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    assert File.read!(baseline) =~ "create table(:retention_settings"
    assert "retention_settings" in Arca.TenantTables.roster()

    now = DateTime.utc_now()
    athanor = "ath_fingerprint_#{System.unique_integer([:positive])}"

    row = %{
      athanor_id: athanor,
      settings: "{}",
      revision: 1,
      inserted_at: now,
      updated_at: now
    }

    # One row per athanor, and a revision that counts from 1.
    assert :ok = insert_row("retention_settings", row)
    assert :refused = insert_row("retention_settings", %{row | revision: 2})

    assert :refused =
             insert_row("retention_settings", %{row | athanor_id: athanor <> "_b", revision: 0})

    assert :refused = insert_row("retention_settings", %{row | athanor_id: nil})
  end

  test "a turn's recovery limit is the fingerprinted baseline's, with no storage default" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    assert File.read!(baseline) =~ ~r/add :recovery_limit, :integer\n/
    assert :recovery_limit in Arca.Schemas.Turn.__schema__(:fields)

    # An accepted turn has no limit yet: the column is nullable and
    # storage supplies none, so a turn row carries only the limit written.
    assert %Arca.Schemas.Turn{}.recovery_limit == nil
  end

  test "the vault, instance-entry and offer tables are the fingerprinted baseline's, rostered" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    source = File.read!(baseline)

    for table <- ~w(vault_defaults file_offers file_receipts) do
      assert source =~ "create table(:#{table}", "#{table} is not in the baseline"
      assert table in Arca.TenantTables.roster()
    end

    for table <- ~w(instance_entries instance_entry_members instance_entry_usage) do
      assert source =~ "create table(:#{table}", "#{table} is not in the baseline"
      assert table in Arca.TenantTables.not_athanor_scoped()
      refute table in Arca.TenantTables.roster()
    end

    # A default is a child of the entry it names: erased before it.
    roster = Arca.TenantTables.roster()
    index = &Enum.find_index(roster, fn table -> table == &1 end)
    assert index.("vault_defaults") < index.("vault_entries")
    assert index.("consent_vault_refs") < index.("vault_entries")

    assert :ok = Arca.TenantTables.verify_roster!()
  end

  test "the baseline refuses an entry without a destination and a second default for a provider" do
    athanor = "ath_fingerprint_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    entry = %{
      id: "vlt_fp_1",
      athanor_id: athanor,
      name: "fp",
      kind: "api_key",
      destination: ~s({"hosts":["api.example.com"],"scheme":"https"}),
      inserted_at: now,
      updated_at: now
    }

    assert :refused = insert_row("vault_entries", Map.delete(entry, :destination))
    assert :ok = insert_row("vault_entries", entry)

    [attach_only] =
      Arca.Repo.all(
        Ecto.Query.from(v in Arca.Schemas.VaultEntry,
          where: v.id == "vlt_fp_1",
          select: v.attach_only
        )
      )

    assert attach_only == true

    default = %{
      id: "vdf_fp_1",
      athanor_id: athanor,
      provider_hint: "example.com",
      vault_entry_id: "vlt_fp_1",
      inserted_at: now,
      updated_at: now
    }

    assert :ok = insert_row("vault_defaults", default)
    assert :refused = insert_row("vault_defaults", %{default | id: "vdf_fp_2"})
  end

  test "the baseline holds an offer's and a receipt's states to their vocabularies" do
    athanor = "ath_fingerprint_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    offer = %{
      id: "fof_fp_1",
      athanor_id: athanor,
      offer_id: "ofr_fp",
      sender_user_id: "usr_a",
      recipient_user_id: "usr_b",
      filename: "a.txt",
      digest: "sha256:x",
      size: 1,
      status: "offered",
      expires_at: now,
      inserted_at: now,
      updated_at: now
    }

    assert :refused = insert_row("file_offers", %{offer | status: "lost"})
    assert :ok = insert_row("file_offers", offer)
    assert :refused = insert_row("file_offers", %{offer | id: "fof_fp_2"})

    receipt = %{
      id: "frc_fp_1",
      athanor_id: athanor,
      offer_id: "ofr_fp",
      sender_user_id: "usr_a",
      recipient_user_id: "usr_b",
      filename: "a.txt",
      digest: "sha256:x",
      size: 1,
      folder: "data/inbox",
      custody_path: "payloads/receipts/ofr_fp/att_fp/a.txt",
      status: "received",
      attempt_path: nil,
      attempt_state: nil,
      inserted_at: now,
      updated_at: now
    }

    # A receipt names the custody copy its acceptance wrote.
    assert :refused = insert_row("file_receipts", Map.delete(receipt, :custody_path))
    assert :refused = insert_row("file_receipts", %{receipt | status: "lost"})
    assert :refused = insert_row("file_receipts", %{receipt | attempt_path: "data/inbox/x"})

    assert :refused =
             insert_row("file_receipts", %{
               receipt
               | attempt_path: "data/inbox/x",
                 attempt_state: "sent"
             })

    assert :ok =
             insert_row("file_receipts", %{
               receipt
               | attempt_path: "data/inbox/x",
                 attempt_state: "chosen"
             })
  end

  defp insert_row(table, row) do
    Arca.Repo.transaction(fn -> Arca.Repo.insert_all(table, [row]) end)
    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end

  defp fingerprint_row, do: from(m in ServerMeta, where: m.key == ^SchemaFingerprint.key())
end
