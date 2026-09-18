# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.StorageCommit do
  @moduledoc """
  Ecto schema for the `storage_commits` table: the journal of a storage
  unit's commits, one row per commit of `Arca.Schemas.StorageUnit`.

  Append-only: a row is inserted in the same transaction that moves the
  unit's pointer, and there is no update or delete path — this module
  offers a changeset for the insert alone, and a journal row goes only
  when its unit's row does. `prior_revision` is nil for the unit's first
  commit; `new_revision` is what the pointer named after it;
  `content_identity` is the digest of the revision's content, and
  `commit_identity` who committed — an attempt, an actor or the system,
  as the writer spells it. Owned by the athanor.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "storage_commits" do
    field :athanor_id, :string
    field :storage_unit_id, :string
    field :prior_revision, :string
    field :new_revision, :string
    field :content_identity, :string
    field :commit_identity, :string
    field :committed_at, :utc_datetime_usec
  end

  @fields [
    :id,
    :athanor_id,
    :storage_unit_id,
    :prior_revision,
    :new_revision,
    :content_identity,
    :commit_identity,
    :committed_at
  ]

  @doc "The insert changeset: the one way a journal row is made."
  def changeset(%__MODULE__{} = row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([
      :id,
      :athanor_id,
      :storage_unit_id,
      :new_revision,
      :content_identity,
      :commit_identity,
      :committed_at
    ])
    |> foreign_key_constraint(:storage_unit_id)
  end
end
