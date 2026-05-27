# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.WebhookDelivery do
  @moduledoc """
  Ecto schema for the `webhook_deliveries` table (backs
  `Arca.WebhookDeliveryStorage`). No `timestamps()` — only `first_seen_at`.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "webhook_deliveries" do
    field :webhook_id, :string
    field :idempotency_key, :string
    field :first_seen_at, :utc_datetime_usec
  end
end
