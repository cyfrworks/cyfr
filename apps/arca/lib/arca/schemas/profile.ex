# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Profile do
  @moduledoc """
  A component the operator granted — stable identity and live revocation
  state only. What the grant *means* lives in the consent revisions;
  `head_consent_id` points at the current one and advances only by
  compare-and-swap.

  `changeset/2` is where a row is held to the profile vocabulary — kind,
  status, the revocation's cause and the label grammar — so every insert
  meets one rule.

  `revoked_by` is who revoked the profile: `person`, by `profile.revoke`,
  or `removal`, when its component's last version was removed. A revoked
  row names one and no other row names any (the `profiles_revoked_by_cause`
  CHECK); there is no default, so a revocation that names no cause is
  refused.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Prima.Authority.RootSelect

  @kinds ~w(owner public)
  # The status vocabulary is the profile table's in `Arca.StatusTransitions`.
  @statuses Arca.StatusTransitions.statuses(:profiles)
  @revocation_causes ~w(person removal)
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
    field :revoked_by, :string
    field :head_consent_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every status a profile row can carry (`Arca.StatusTransitions.statuses(:profiles)`)."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Who can have revoked a profile: its person, or a removal of its component."
  @spec revocation_causes() :: [String.t()]
  def revocation_causes, do: @revocation_causes

  @doc """
  A profile row about to be inserted.

  The label rule has one owner — `Prima.Authority.RootSelect.valid_label?/1`,
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
    |> validate_revocation()
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

  # A revoked row names its cause, and no other row names one.
  defp validate_revocation(changeset) do
    case {get_field(changeset, :status), get_field(changeset, :revoked_by)} do
      {"revoked", cause} when cause in @revocation_causes ->
        changeset

      {"revoked", _cause} ->
        add_error(changeset, :revoked_by, "must name who revoked it")

      {_status, nil} ->
        changeset

      {_status, _cause} ->
        add_error(changeset, :revoked_by, "names a revocation of no revoked row")
    end
  end

  @doc """
  The label rule in its typed form — `Prima.Authority.RootSelect.check_label/1`,
  which owns the rule this row is held to and which the consent verbs
  answer with before a plan token or proof is minted for a label.
  """
  @spec check_label(term()) :: :ok | {:error, {:invalid_label, term()}}
  defdelegate check_label(label), to: RootSelect
end
