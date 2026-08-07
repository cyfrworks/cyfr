# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.CreateConsentVaultRefs do
  use Ecto.Migration

  # The derived reverse index over a consent's vault references, written in
  # the same transaction as the revision. The loader refuses any consent
  # whose blob disagrees with these rows, and "which profiles can touch
  # this entry" is one query here. No surrogate id: rows are only ever
  # inserted with their revision and queried by consent or entry.
  def change do
    create table(:consent_vault_refs, primary_key: false) do
      add :consent_id, references(:consents, column: :id, type: :string), null: false
      add :org_id, :string, null: false, default: ""

      add :vault_entry_id,
          references(:vault_entries, column: :id, type: :string, with: [org_id: :org_id]),
          null: false

      add :binding_digest, :string, null: false
    end

    create unique_index(:consent_vault_refs, [:consent_id, :vault_entry_id])
    create index(:consent_vault_refs, [:vault_entry_id, :org_id])
  end
end
