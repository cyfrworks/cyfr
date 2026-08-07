# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateConsentProofs do
  use Ecto.Migration

  # Server-minted single-use consent proofs (delete-on-read; the OAuth
  # authorization-code state is the precedent). The primary key is the
  # sha256 of the token, never the token itself — a leaked table cannot
  # replay a proof. Rows live minutes; no FKs on purpose (the bindings
  # comparison at consume time is the integrity check, and a dangling
  # profile reference must burn, not error).
  def change do
    create table(:consent_proofs, primary_key: false) do
      add :token_hash, :string, primary_key: true
      add :kind, :string, null: false
      add :digest, :string, null: false
      add :bindings, :text, null: false, default: "{}"
      add :org_id, :string, null: false, default: ""
      add :project_id, :string, null: false, default: "default"
      add :expires_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:consent_proofs, [:expires_at])
  end
end
