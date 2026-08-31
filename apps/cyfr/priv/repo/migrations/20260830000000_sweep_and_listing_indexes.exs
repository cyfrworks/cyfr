# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.SweepAndListingIndexes do
  use Ecto.Migration

  # Two queries that had no index to walk.
  #
  # `sessions.expires_at` — `Arca.SessionStorage.cleanup_expired_sessions/0`
  # deletes every row past its expiry. The table carried only `token_hash`
  # (unique) and `user_id`, so the sweep was a full scan. It never ran in
  # production before now (nothing called `Sanctum.Session.cleanup/0`), which
  # is why the missing index went unnoticed: the table just grew. The
  # retention scheduler runs it every six hours as of this change.
  #
  # `api_keys.athanor_id` — the existing partial index is
  # `(athanor_id, name) WHERE NOT revoked`, which serves lookup of a live key
  # by name and nothing else. Listing an athanor's keys *including* revoked
  # ones — what the console and `key.list` do — scanned the table.
  def change do
    create index(:sessions, [:expires_at])
    create index(:api_keys, [:athanor_id])
  end
end
