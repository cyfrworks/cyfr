# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DropLegacyCredentialTables do
  use Ecto.Migration

  # The credential planes these tables backed are deleted: vault entries
  # (sealed, consent-bound) are the only credential store. v1 legacy
  # pointer entries referenced rows in these tables, so they tombstone in
  # the same step — re-granting mints fresh material (the no-compat
  # major's contract; the upgrade guide says so).
  def up do
    execute(
      "UPDATE vault_entries SET status = 'tombstoned', sealed_payload = NULL " <>
        "WHERE provider_hint = 'legacy'"
    )

    drop_if_exists(table(:secret_grants))
    drop_if_exists(table(:secrets))
    drop_if_exists(table(:oauth_credentials))
  end

  def down do
    # Deliberately irreversible: the planes that read these tables no
    # longer exist, and resurrecting empty tables would only invite
    # something to write credentials nothing can consume.
    :ok
  end
end
