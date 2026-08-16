# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Profile do
  @moduledoc """
  A component the operator granted — stable identity and live revocation
  state only. What the grant *means* lives in the consent revisions;
  `head_consent_id` points at the current one and advances only by
  compare-and-swap.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "profiles" do
    field :athanor_id, :string
    field :source_ref, :string
    field :kind, :string, default: "owner"
    field :label, :string, default: "default"
    field :status, :string, default: "active"
    field :head_consent_id, :string

    timestamps(type: :utc_datetime_usec)
  end
end
