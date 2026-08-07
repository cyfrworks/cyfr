# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateRegistryTokens do
  use Ecto.Migration

  def change do
    create table(:registry_tokens, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :registry, :string, null: false
      add :namespace_slug, :string, null: false
      add :credential_ciphertext, :binary, null: false
      add :issued_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:registry_tokens, [:user_id, :registry, :namespace_slug])
    create index(:registry_tokens, [:user_id, :registry])
  end
end
