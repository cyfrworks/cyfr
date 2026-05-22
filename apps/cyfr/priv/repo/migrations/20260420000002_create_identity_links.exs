# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateIdentityLinks do
  use Ecto.Migration

  def change do
    create table(:identity_links, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :provider, :string, null: false
      add :provider_subject, :string, null: false
      add :access_token_ciphertext, :binary
      add :linked_at, :utc_datetime_usec, null: false
    end

    create unique_index(:identity_links, [:user_id, :provider])
    create index(:identity_links, [:user_id])
  end
end
