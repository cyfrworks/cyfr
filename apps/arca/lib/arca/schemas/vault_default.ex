# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.VaultDefault do
  @moduledoc """
  An athanor's default entry for one provider (`provider_hint`): exactly
  one of its own vault entries (`vault_entry_id`, held to the athanor by
  the composite key) or an instance entry offered to its members
  (`instance_entry_id`). One row per `(athanor_id, provider_hint)`.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "vault_defaults" do
    field :athanor_id, :string
    field :provider_hint, :string
    field :vault_entry_id, :string
    field :instance_entry_id, :string

    timestamps(type: :utc_datetime_usec)
  end
end
