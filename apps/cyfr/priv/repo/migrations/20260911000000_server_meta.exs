# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ServerMeta do
  use Ecto.Migration

  # The server's own facts, one row per key — the fingerprint of the
  # keyring this database was sealed with, and which boot owns the control
  # plane. Neither belongs to an athanor, so the table carries no
  # `athanor_id` (`Arca.TenantTables` lists it as not athanor-scoped).
  #
  # It lives in the database rather than a file on the volume for the
  # reason `docs/keyring-fingerprint.md` gives: two nodes sharing one
  # database must read one answer, and a restore that brings back the
  # database without the volume (or the reverse) must not get a false one.
  def up do
    create table(:server_meta, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    drop table(:server_meta)
  end
end
