# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ConsentVaultRef do
  @moduledoc """
  The derived reverse index over a consent revision's vault references,
  written in the same transaction as the revision. No surrogate id: rows
  are inserted once and queried by consent or entry, never addressed
  individually.
  """

  use Ecto.Schema

  @primary_key false
  schema "consent_vault_refs" do
    field :consent_id, :string
    field :org_id, :string, default: ""
    field :vault_entry_id, :string
    field :binding_digest, :string
  end
end
