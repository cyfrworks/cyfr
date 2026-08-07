# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Webhook do
  @moduledoc """
  Ecto schema for the `webhooks` table (backs `Arca.WebhookStorage`).
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "webhooks" do
    field :name, :string
    field :slug, :string
    field :target_ref, :string
    field :secret_encrypted, :binary
    field :previous_secret_encrypted, :binary
    field :previous_secret_expires_at, :utc_datetime_usec
    field :signature_header, :string
    field :timestamp_header, :string
    field :idempotency_key_header, :string
    field :input_template, :string
    field :description, :string
    field :enabled, :boolean
    field :rate_limit, :string
    field :created_by, :string
    field :profile_id, :string
    field :rotated_at, :utc_datetime_usec
    field :scope_type, :string
    field :org_id, :string
    field :project_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
