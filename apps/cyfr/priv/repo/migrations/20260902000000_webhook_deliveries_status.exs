# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.WebhookDeliveriesStatus do
  use Ecto.Migration

  # The idempotency claim followed the RESPONSE, not the work.
  #
  # `EmissaryWeb.WebhookController` answers `200 accepted` the instant
  # `Task.Supervisor.start_child/2` returns, so the plug's
  # `register_before_send` release — gated on a non-2xx status — could
  # never fire for a delivery that failed inside the task. Every execution
  # outcome happens after the response. A delivery whose component raised
  # kept its claim, and the sender's retry was answered `"duplicate"` for
  # the full TTL: the exact case the plug's own moduledoc says it exists to
  # handle.
  #
  # A claim needs a lifecycle to be releasable by the thing that knows the
  # outcome. `claimed` is staked before the work, `succeeded` holds the
  # claim, `failed` makes the delivery re-deliverable so a retry re-claims
  # it rather than being told it already ran.
  #
  # `default: "claimed"` is what lets an existing table take a NOT NULL
  # column, and it is also the right reading of a row written before this
  # existed: it was staked, and nothing recorded that it finished.
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
