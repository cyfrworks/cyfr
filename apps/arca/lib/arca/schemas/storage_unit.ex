# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.StorageUnit do
  @moduledoc """
  Ecto schema for the `storage_units` table: the pointer that publishes
  one unit under a seeded root.

  A unit is what its root's locator answers (`Arca.Storage.UnitLocator`):
  a component version directory, an aqua agent or skill. `root` is the
  seeded root (`Arca.Storage.overlay_roots/0`) and `unit_key` the unit's
  path inside it, segments joined with `/`; the pair is unique per athanor.
  `current_revision` names the committed, immutable revision readers see
  — a complete object set under the unit's prefix is staging until a
  commit names it. `draft_writer_token` is held by the one writer staging
  the next revision: a commit compares it and clears it, so a writer that
  lost the token cannot commit what it staged. Every commit appends one
  `Arca.Schemas.StorageCommit`.

  A row says what is published and nothing about what was published: a
  component release's activation identity is the `components` row's
  (`Compendium.ReleaseDigest`), the bytes' identity is the journal's
  `content_identity`, and neither is copied here to go stale.

  ## States

    * `draft` — registered, nothing committed: `current_revision` is nil
      and readers see no unit.
    * `committed` — the pointer names a revision. A later draft against
      it keeps the state (readers keep the committed revision) and is
      visible as a non-nil `draft_writer_token`.
    * `retired` — the unit was dropped; the pointer keeps its last
      revision for the journal's sake and readers see no unit.

  Transitions: `draft → committed` on the first commit; `committed →
  committed` on every later one; `draft → retired` when an abandoned
  draft is cleaned up; `committed → retired` on a drop; `retired →
  draft` when a writer registers the same key again — the row is reused,
  the journal keeps every earlier commit.

  Owned by the athanor.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  @typedoc """
  What a commit answers, the one vocabulary the storage-unit facade
  returns:

    * `:committed` — the pointer moved and the journal grew by one row.
    * `{:error, :stale_revision}` — the pointer no longer names the
      revision the writer staged against; another commit landed first.
    * `{:error, :stale_writer}` — the unit's `draft_writer_token` is not
      the writer's; another writer took the draft.
    * `{:error, :missing_unit}` — no row for the key, or the unit is
      retired.
    * `{:error, :invalid_objects}` — the staged object set is not a
      complete, valid revision; nothing was committed.
    * `{:error, :outcome_unknown}` — the store could not answer; the
      outcome is unknown to the writer and nothing may be assumed.
  """
  @type commit_result ::
          :committed
          | {:error,
             :stale_revision
             | :stale_writer
             | :missing_unit
             | :invalid_objects
             | :outcome_unknown}

  @states ~w(draft committed retired)

  schema "storage_units" do
    field :athanor_id, :string
    field :root, :string
    field :unit_key, :string
    field :state, :string, default: "draft"
    field :current_revision, :string
    field :draft_writer_token, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The unit states, in lifecycle order."
  @spec states() :: [String.t()]
  def states, do: @states

  @fields [
    :id,
    :athanor_id,
    :root,
    :unit_key,
    :state,
    :current_revision,
    :draft_writer_token
  ]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required([:id, :athanor_id, :root, :unit_key, :state])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:root, Arca.Storage.overlay_roots())
    |> unique_constraint([:athanor_id, :root, :unit_key])
  end
end
