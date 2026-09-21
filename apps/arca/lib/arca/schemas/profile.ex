# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Profile do
  @moduledoc """
  A component the operator granted — stable identity and live revocation
  state only. What the grant *means* lives in the consent revisions;
  `head_consent_id` points at the current one and advances only by
  compare-and-swap.

  `changeset/2` is where a row is held to the profile vocabulary — kind,
  status, and the label grammar — so every insert meets one rule.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Cyfr.Authority.RootSelect

  @kinds ~w(owner public)
  @statuses ~w(active needs_consent revoked)
  @required [:id, :athanor_id, :source_ref, :kind, :label, :status]
  @identity [:athanor_id, :source_ref, :label, :kind]

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "profiles" do
    field :athanor_id, :string
    field :source_ref, :string
    field :kind, :string, default: "owner"
    field :label, :string, default: "default"
    field :status, :string, default: "active"
    field :head_consent_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  A profile row about to be inserted.

  The label rule has one owner — `Cyfr.Authority.RootSelect.valid_label?/1`,
  whose `decode/1` tells an id from a label by the `prof_` prefix and is
  only sound while no stored label wears it — and this is where a write is
  held to it. The active-identity index rides along so a race answers
  `{:error, changeset}` instead of raising past the db-error rescue.

  Built with `change/2`, not `cast/4`: the attrs come from the consent
  layer, never from the wire, and a cast would quietly swap an empty label
  for the column default where the rule says refuse.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = profile, attrs) when is_map(attrs) do
    profile
    |> change(attrs)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:label, fn :label, label ->
      case check_label(label) do
        :ok -> []
        {:error, _} -> [label: "must be non-empty and not shaped like a profile id"]
      end
    end)
    # The active-identity index under BOTH names an adapter can report it
    # by: Postgres names the index the migration named; SQLite cannot name
    # a violated index and reports its columns, from which `ecto_sqlite3`
    # derives Ecto's default name. One declaration would match one adapter
    # and raise on the other.
    |> unique_constraint(@identity, name: :profiles_active_identity_index)
    |> unique_constraint(@identity)
  end

  @doc """
  The label rule in its typed form — `Cyfr.Authority.RootSelect.check_label/1`,
  which owns the rule this row is held to and which the consent verbs
  answer with before a plan token or proof is minted for a label.
  """
  @spec check_label(term()) :: :ok | {:error, {:invalid_label, term()}}
  defdelegate check_label(label), to: RootSelect
end
