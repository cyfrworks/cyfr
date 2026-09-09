# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.WebhookDeliveriesStatus do
  use Ecto.Migration

  # Track asynchronous delivery outcomes independently of HTTP acceptance.
  # A claimed or succeeded delivery retains its idempotency claim; a failed
  # delivery can be reclaimed by a retry. Existing rows default to claimed.
  def up do
    alter table(:webhook_deliveries) do
      add :status, :string, null: false, default: "claimed"
      add :settled_at, :utc_datetime_usec
    end

    # The sweep reclaims by age; `retention` walks `first_seen_at`. This
    # index serves the other question — "which claims never settled" —
    # which is how a stuck delivery is found rather than waited out.
    create index(:webhook_deliveries, [:status, :first_seen_at])
  end

  def down do
    drop index(:webhook_deliveries, [:status, :first_seen_at])

    alter table(:webhook_deliveries) do
      remove :settled_at
      remove :status
    end
  end
end
