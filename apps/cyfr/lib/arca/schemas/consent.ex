# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Consent do
  @moduledoc """
  One immutable consent revision. Rows are only ever inserted — the
  storage layer exports no update function, and `granted_at` is the only
  timestamp a revision can carry because nothing else ever happens to it.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "consents" do
    field :athanor_id, :string
    field :profile_id, :string
    field :revision, :integer
    field :scope, :string
    field :pinned_version, :string, default: ""
    field :invoke_mode, :string, default: "open_inert"
    field :shape_digest, :string
    field :commit_digest, :string
    # The hash of `resolved_policy`. `commit_digest` covers this column,
    # not the blob, so without it nothing on the row detects a policy
    # altered in place after the fact.
    field :blob_digest, :string
    field :resolved_policy, :binary
    field :activation, :binary
    field :granted_by, :string
    field :granted_via, :string
    field :granted_at, :utc_datetime_usec
    field :supersedes_id, :string
  end
end
