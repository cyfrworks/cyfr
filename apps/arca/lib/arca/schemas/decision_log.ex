# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.DecisionLog do
  @moduledoc """
  One admission decision row: the stored form of `Prima.Decision`. The
  facade is `Arca.DecisionLog`.

  ## Schema

  - `call_id` (PK) - the call the decision is about
  - `parent_call_id` - the call that admitted the execution this call runs under
  - `request_id` - the transport's correlation id a chain shares
  - `user_id` - who called; null for a refusal before any caller was established
  - `athanor_id` - the tenant; null for a refusal before any tenant was
    resolved, and such a row is the host's, not a tenant's
  - `plane` - external/in_chain
  - `tool`, `action` - the operation
  - `admission` - admitted/refused
  - `refusal_class` - a refusal's class (`Prima.Refusal.classes/0`)
  - `reason` - the refusal's operator sentence
  - `inserted_at` - when the gate decided
  - `completion` - succeeded/failed/cancelled/uncertain, null until finished
  - `completion_class` - a failure's class
  - `completed_at`, `duration_ms` - when the work ended and how long it ran

  Atoms are stored as their names; the vocabularies are `Prima.Decision`'s
  and `Prima.Refusal`'s.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:call_id, :string, autogenerate: false}
  @timestamps_opts []

  schema "decision_logs" do
    field :parent_call_id, :string
    field :request_id, :string
    field :user_id, :string
    field :athanor_id, :string
    field :plane, :string
    field :tool, :string
    field :action, :string
    field :admission, :string
    field :refusal_class, :string
    field :reason, :string
    field :inserted_at, :utc_datetime_usec
    field :completion, :string
    field :completion_class, :string
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
  end

  @admission_fields [
    :call_id,
    :parent_call_id,
    :request_id,
    :user_id,
    :athanor_id,
    :plane,
    :tool,
    :action,
    :admission,
    :refusal_class,
    :reason,
    :inserted_at
  ]

  @doc "The columns an admission writes."
  @spec admission_fields() :: [atom()]
  def admission_fields, do: @admission_fields

  @doc "The columns a completion writes."
  @spec completion_fields() :: [atom()]
  def completion_fields, do: [:completion, :completion_class, :completed_at, :duration_ms]

  @doc "A changeset for a new row from its admission's stored columns."
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @admission_fields)
    |> validate_required([:call_id, :plane, :admission, :inserted_at])
    |> validate_inclusion(:plane, Enum.map(Prima.Decision.planes(), &Atom.to_string/1))
    |> validate_inclusion(:admission, Enum.map(Prima.Decision.admissions(), &Atom.to_string/1))
    |> validate_inclusion(:refusal_class, Enum.map(Prima.Refusal.classes(), &Atom.to_string/1))
  end
end
