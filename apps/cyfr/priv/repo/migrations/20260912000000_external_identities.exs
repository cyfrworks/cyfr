# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.ExternalIdentities do
  use Ecto.Migration

  # A person is a `users` row with an id of this server's (`usr_…`); how an
  # identity provider names them is a row here, keyed by the IdP composite
  # `<provider>|<issuer>|<subject>`. One person may be named by several.
  # No `athanor_id`: identities belong to the person, not to any estate.
  def change do
    create table(:external_identities, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :provider, :string, null: false
      add :issuer, :string, null: false
      add :subject, :string, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:external_identities, [:key])
    create index(:external_identities, [:user_id])
  end
end
