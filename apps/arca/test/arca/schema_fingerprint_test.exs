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

  test "the vault and offer tables are the fingerprinted baseline's, rostered" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    source = File.read!(baseline)

    for table <- ~w(vault_defaults file_offers file_receipts) do
      assert source =~ "create table(:#{table}", "#{table} is not in the baseline"
      assert table in Arca.TenantTables.roster()
    end

    # A default is a child of the entry it names: erased before it.
    roster = Arca.TenantTables.roster()
    index = &Enum.find_index(roster, fn table -> table == &1 end)
    assert index.("vault_defaults") < index.("vault_entries")
    assert index.("consent_vault_refs") < index.("vault_entries")

    assert :ok = Arca.TenantTables.verify_roster!()
  end

  test "the share tables are the fingerprinted baseline's, rostered children of the entries" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    source = File.read!(baseline)
    roster = Arca.TenantTables.roster()
    index = &Enum.find_index(roster, fn table -> table == &1 end)

    for table <- ~w(shares share_usage) do
      assert source =~ "create table(:#{table}", "#{table} is not in the baseline"
      assert table in roster
    end

    # Erased usage first, then shares, then the entries they name.
    assert index.("share_usage") < index.("shares")
    assert index.("shares") < index.("vault_entries")
    assert :ok = Arca.TenantTables.verify_roster!()
  end

  test "the baseline holds a share to its own athanor's entry, its audience and its natural key" do
    athanor = "ath_fingerprint_#{System.unique_integer([:positive])}"
    other = athanor <> "_b"
    now = DateTime.utc_now()

    for {id, at} <- [{"vlt_sh_1", athanor}, {"vlt_sh_2", other}] do
      assert :ok =
               insert_row("vault_entries", %{
                 id: id,
                 athanor_id: at,
                 name: id,
                 kind: "api_key",
                 destination: ~s({"hosts":["api.example.com"],"scheme":"https"}),
                 inserted_at: now,
                 updated_at: now
               })
    end

    share = %{
      id: "shr_fp_1",
      athanor_id: athanor,
      vault_entry_id: "vlt_sh_1",
      audience: "everyone",
      group_id: nil,
      status: "active",
      created_by: "usr_a",
      inserted_at: now,
      updated_at: now
    }

    assert :ok = insert_row("shares", share)

    # Another athanor's entry is no entry a share of this one may name.
    assert refused("shares", %{share | id: "shr_fp_2", vault_entry_id: "vlt_sh_2"}) =~
             ~r/foreign key/i

    # One active share per entry and audience, an absent group included;
    # a revoked one stands beside it.
    assert refused("shares", %{share | id: "shr_fp_3"}) =~ "shares_active_audience_index"
    assert :ok = insert_row("shares", %{share | id: "shr_fp_4", status: "revoked"})

    group = %{share | id: "shr_fp_5", audience: "group", group_id: "ath_traders"}
    assert :ok = insert_row("shares", group)
    assert refused("shares", %{group | id: "shr_fp_6"}) =~ "shares_active_audience_index"
    assert :ok = insert_row("shares", %{group | id: "shr_fp_7", group_id: "ath_pair"})

    # A group exactly when the audience is one.
    for bad <- [
          %{group | id: "shr_fp_8", group_id: nil},
          %{group | id: "shr_fp_9", group_id: ""},
          %{share | id: "shr_fp_10", group_id: "ath_traders"}
        ] do
      assert refused("shares", bad) =~ "shares_group_named"
    end

    usage = %{
      athanor_id: athanor,
      share_id: "shr_fp_1",
      user_id: "usr_b",
      day: Date.utc_today(),
      count: 1,
      updated_at: now
    }

    assert :ok = insert_row("share_usage", usage)

    assert refused("share_usage", %{usage | athanor_id: other, user_id: "usr_c"}) =~
             ~r/foreign key/i
  end

  test "the baseline holds a binding to exactly one identity, a share's beside the others" do
    athanor = "ath_fingerprint_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    assert :ok =
             insert_row("vault_entries", %{
               id: "vlt_ref_1",
               athanor_id: athanor,
               name: "ref",
               kind: "api_key",
               destination: ~s({"hosts":["api.example.com"],"scheme":"https"}),
               inserted_at: now,
               updated_at: now
             })

    assert :ok =
             insert_row("profiles", %{
               id: "prof_ref_1",
               athanor_id: athanor,
               source_ref: "formula:local.ref",
               inserted_at: now,
               updated_at: now
             })

    assert :ok =
             insert_row("consents", %{
               id: "cons_ref_1",
               athanor_id: athanor,
               profile_id: "prof_ref_1",
               revision: 1,
               scope: "versionless",
               shape_digest: "s",
               commit_digest: "c",
               resolved_policy: "{}",
               blob_digest: "b",
               activation: "{}",
               granted_by: "t",
               granted_via: "t",
               granted_at: now,
               admitted_origins: ~s(["interactive"])
             })

    ref = %{
      consent_id: "cons_ref_1",
      athanor_id: athanor,
      binding_key: "k1",
      share_id: "shr_elsewhere",
      binding_digest: "sha256:d0"
    }

    # A share-only row stands, and so do an entry's and a selection's, a
    # selection with no pin among them.
    assert :ok = insert_row("consent_vault_refs", ref)

    assert :ok =
             insert_row(
               "consent_vault_refs",
               %{ref | binding_key: "k2", share_id: nil} |> Map.put(:vault_entry_id, "vlt_ref_1")
             )

    assert :ok =
             insert_row(
               "consent_vault_refs",
               %{ref | binding_key: "k3", share_id: nil} |> Map.put(:via_label, "default")
             )

    assert :ok =
             insert_row(
               "consent_vault_refs",
               %{ref | binding_key: "k4", share_id: nil, binding_digest: nil}
               |> Map.put(:via_label, "default")
             )

    # Two identities, none, or an entry or a share with no digest.
    for {key, bad} <- [
          {"k5", Map.put(ref, :vault_entry_id, "vlt_ref_1")},
          {"k6", Map.put(ref, :via_label, "default")},
          {"k7", %{ref | share_id: nil}},
          {"k8", %{ref | binding_digest: nil}},
          {"k9",
           %{ref | share_id: nil, binding_digest: nil} |> Map.put(:vault_entry_id, "vlt_ref_1")},
          {"k10",
           %{ref | share_id: nil}
           |> Map.put(:vault_entry_id, "vlt_ref_1")
           |> Map.put(:via_label, "x")}
        ] do
      assert refused("consent_vault_refs", %{bad | binding_key: key}) =~
               "consent_vault_refs_names_one"
    end
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

  test "a frame credential's purpose is the fingerprinted baseline's: live unless named, one of two" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    assert File.read!(baseline) =~ ~r/add :purpose, :text, null: false, default: "live"/
    assert :purpose in Arca.Schemas.FrameCredential.__schema__(:fields)

    now = DateTime.utc_now()

    row = %{
      id: "frcp_fp_1",
      athanor_id: "ath_fingerprint_#{System.unique_integer([:positive])}",
      user_id: "usr_fp",
      publisher: "acme",
      name: "dash",
      version: "1.0.0",
      version_digest: "sha256:x",
      grant_revision: 0,
      frame_id: "frm_fp_1",
      source_kind: "session",
      source_id: "c2Vzc2lvbg",
      deadline: now,
      inserted_at: now,
      updated_at: now
    }

    assert :ok = insert_row("frame_credentials", row)

    assert ["live"] ==
             Arca.Repo.all(
               from(f in "frame_credentials", where: f.id == "frcp_fp_1", select: f.purpose)
             )

    validation = %{row | id: "frcp_fp_2", frame_id: "frm_fp_2"}
    assert :ok = insert_row("frame_credentials", Map.put(validation, :purpose, "validation"))

    for {purpose, n} <- [{"trial", 3}, {"", 4}, {nil, 5}] do
      assert :refused =
               insert_row(
                 "frame_credentials",
                 Map.merge(row, %{id: "frcp_fp_#{n}", frame_id: "frm_fp_#{n}", purpose: purpose})
               ),
             "purpose #{inspect(purpose)} was accepted"
    end
  end

  test "a feed is the fingerprinted baseline's: a kind, a spec exactly for a feed, a live name once per kind" do
    [baseline] =
      Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

    assert File.read!(baseline) =~ ~r/add :kind, :string, null: false, default: "schedule"/

    for field <- ~w(kind feed_spec feed_fire_seq feed_result_seq feed_result feed_result_at)a do
      assert field in Arca.Schemas.CronSchedule.__schema__(:fields)
    end

    now = DateTime.utc_now()

    row = %{
      id: "sched_fp_1",
      athanor_id: "ath_fingerprint_#{System.unique_integer([:positive])}",
      user_id: "usr_fp",
      name: "btc",
      cron_expression: "*/5 * * * *",
      reference: "catalyst:local.markets",
      resolved_reference: "catalyst:local.markets:1.0.0",
      profile_id: "prof_fp",
      created_at: now,
      updated_at: now
    }

    # A row is a schedule unless it says otherwise, with no spec and no seq.
    assert :ok = insert_row("cron_schedules", row)

    assert [{"schedule", nil, 0, 0}] ==
             Arca.Repo.all(
               from(c in "cron_schedules",
                 where: c.id == "sched_fp_1",
                 select: {c.kind, c.feed_spec, c.feed_fire_seq, c.feed_result_seq}
               )
             )

    # A feed may hold a schedule's live name, but not another live feed's.
    feed = Map.merge(row, %{id: "feed_fp_2", kind: "feed", feed_spec: "{}"})
    assert :ok = insert_row("cron_schedules", feed)
    assert :refused = insert_row("cron_schedules", %{feed | id: "feed_fp_3"})

    assert :ok =
             insert_row("cron_schedules", Map.merge(feed, %{id: "feed_fp_4", status: "deleted"}))

    # A feed carries its spec, a schedule carries none, and no third kind is.
    for {wrong, n} <- [
          {%{kind: "feed", feed_spec: nil}, 5},
          {%{kind: "schedule", feed_spec: "{}"}, 6},
          {%{kind: "card", feed_spec: nil}, 7},
          {%{kind: nil, feed_spec: nil}, 8}
        ] do
      attempt = Map.merge(row, Map.merge(wrong, %{id: "sched_fp_#{n}", name: "fp-#{n}"}))
      assert :refused = insert_row("cron_schedules", attempt), "#{inspect(wrong)} was accepted"
    end
  end

  defp insert_row(table, row) do
    Arca.Repo.transaction(fn -> Arca.Repo.insert_all(table, [row]) end)
    :ok
  rescue
    _refused in Arca.Repo.Errors.db_errors() -> :refused
  end

  # The driver's word for a row the baseline refuses, naming the rule.
  defp refused(table, row) do
    Arca.Repo.transaction(fn -> Arca.Repo.insert_all(table, [row]) end)
    flunk("#{table} took #{inspect(row)}")
  rescue
    error in Arca.Repo.Errors.db_errors() -> Exception.message(error)
  end

  defp fingerprint_row, do: from(m in ServerMeta, where: m.key == ^SchemaFingerprint.key())
end
