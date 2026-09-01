# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.WebhookDelivery do
  @moduledoc """
  Ecto schema for the `webhook_deliveries` table (backs
  `Arca.WebhookDeliveryStorage`). No `timestamps()` — only `first_seen_at`.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "webhook_deliveries" do
    field :webhook_id, :string
    field :idempotency_key, :string
    field :first_seen_at, :utc_datetime_usec
    # `claimed` while the delivery is in flight, then `succeeded` or
    # `failed`. A failed claim is re-deliverable — the sender's retry
    # re-claims it — which is the whole reason the claim outlives the
    # response it used to be released by.
    field :status, :string, default: "claimed"
    field :settled_at, :utc_datetime_usec
  end
end
