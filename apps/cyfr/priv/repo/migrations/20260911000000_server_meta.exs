# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ServerMeta do
  use Ecto.Migration

  # Server-wide metadata keyed by name, including the sealing-keyring
  # fingerprint and control-plane boot owner. These rows are not
  # athanor-scoped and are shared by all nodes using this database.
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
