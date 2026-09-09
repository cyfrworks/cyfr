# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExecutionPayloads do
  use Ecto.Migration

  # An execution's retained input or result, as a reference: the digest
  # and size of the bytes, where they live under the athanor's
  # `payloads/` root, and the retention class that decides how long. The
  # row is the athanor's; the bytes are at
  # `data/athanors/<id>/payloads/<execution_id>/<kind>`.
  def change do
    create table(:execution_payloads, primary_key: false) do
      add :id, :string, primary_key: true
      add :athanor_id, :string, null: false
      add :execution_id, :string, null: false
      # input | result
      add :kind, :string, null: false
      add :digest, :string, null: false
      add :bytes, :integer, null: false
      add :blob_ref, :string, null: false
      add :retention_class, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:execution_payloads, [:execution_id, :kind])
    create index(:execution_payloads, [:athanor_id, :retention_class, :inserted_at])
  end
end
