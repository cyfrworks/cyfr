# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.SweepAndListingIndexes do
  use Ecto.Migration

  # Index session expiry for retention sweeps and athanor_id for API-key
  # listings that include revoked keys.
  def change do
    create index(:sessions, [:expires_at])
    create index(:api_keys, [:athanor_id])
  end
end
