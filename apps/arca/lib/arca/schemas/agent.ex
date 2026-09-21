# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Agent do
  @moduledoc """
  One of the estate's agents — the soul or a role — as a derived index row
  of its file in the `aqua/` tree: the digest of the bytes (revision) and
  of the security-relevant subset (capability). Owned by the athanor;
  rewritten from the tree by `Compendium.AgentIndex`.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "agents" do
    field :athanor_id, :string
    field :name, :string
    field :kind, :string
    field :revision_digest, :string
    field :capability_digest, :string
    field :catalyst_ref, :string
    field :disabled, :boolean, default: false
    field :synced_at, :utc_datetime_usec
  end
end
