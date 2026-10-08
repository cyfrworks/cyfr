# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.InstanceEntry do
  @moduledoc """
  A credential the instance owns and offers to the people on it: a vault
  entry's columns less the athanor, plus who it is offered to
  (`audience`: `everyone`, or the `listed` people), the components it
  admits (`component_policy`: `any` or `shipped`), its daily caps
  (`person_daily`, `total_daily`; `nil` takes the platform setting's
  default) and who created it. Always attach-only.

  `sealed_payload` arrives encrypted by Sanctum; Arca stores bytes. The
  vocabularies are spelled here and in the baseline's checks, so a value
  outside them is refused by the changeset and, written around it, by the
  database.
  """

  @max_cap 2_147_483_647

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  @policies ~w(any shipped)
  @audiences ~w(everyone listed)
  @statuses ~w(active needs_reauth revoked tombstoned)

  schema "instance_entries" do
    field :name, :string
    field :provider_hint, :string, default: ""
    field :kind, :string
    field :provenance, :string, default: "user"
    field :field_names, :string, default: "[]"
    field :binding_digest, :string
    field :oauth_endpoints, :string
    field :oauth_scopes, :string
    field :destination, :string
    field :attach_only, :boolean, default: true
    field :status, :string, default: "active"
    field :payload_rev, :integer, default: 0
    field :sealed_payload, :binary
    field :last_used_at, :utc_datetime_usec
    field :audience, :string
    field :person_daily, :integer
    field :total_daily, :integer
    field :component_policy, :string, default: "any"
    field :created_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The component policies an instance entry may carry."
  @spec policies() :: [String.t()]
  def policies, do: @policies

  @doc "The audiences an instance entry may be offered to."
  @spec audiences() :: [String.t()]
  def audiences, do: @audiences

  @doc "The statuses an instance entry may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  A new row, held to the vocabularies: every required column present, the
  audience, status and component policy in theirs, `attach_only` true and
  each cap absent or an integer from 0 to `max_cap/0`. An omitted policy
  takes the column's `any`; a policy given as anything but one of the two
  words is refused.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :name,
      :provider_hint,
      :kind,
      :provenance,
      :field_names,
      :binding_digest,
      :oauth_endpoints,
      :oauth_scopes,
      :destination,
      :attach_only,
      :status,
      :sealed_payload,
      :audience,
      :person_daily,
      :total_daily,
      :created_by
    ])
    |> put_policy(attrs)
    |> validate_required([
      :id,
      :name,
      :kind,
      :destination,
      :audience,
      :created_by,
      :sealed_payload,
      :binding_digest
    ])
    |> validate_inclusion(:audience, @audiences)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:attach_only, [true],
      message: "an instance entry is always attach-only"
    )
    |> validate_number(:person_daily,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_cap
    )
    |> validate_number(:total_daily, greater_than_or_equal_to: 0, less_than_or_equal_to: @max_cap)
  end

  @doc """
  The largest daily cap an instance entry holds: the columns are 32-bit
  integers on PostgreSQL, so a larger cap is refused here on both adapters
  rather than by one driver alone.
  """
  @spec max_cap() :: pos_integer()
  def max_cap, do: @max_cap

  @doc """
  Whether `policy` is a component policy a write may set: exactly one of
  `policies/0`, as a string. Null, the empty string, a list, a map or an
  unknown word is not.
  """
  @spec policy?(term()) :: boolean()
  def policy?(policy), do: is_binary(policy) and policy in @policies

  # Only omission takes the column default; a policy that is present is one
  # of the two words or the row is refused.
  defp put_policy(changeset, attrs) do
    case fetch_policy(attrs) do
      :error ->
        changeset

      {:ok, policy} ->
        if policy?(policy),
          do: put_change(changeset, :component_policy, policy),
          else: add_error(changeset, :component_policy, "is any or shipped")
    end
  end

  defp fetch_policy(attrs) do
    case Map.fetch(attrs, :component_policy) do
      {:ok, policy} -> {:ok, policy}
      :error -> Map.fetch(attrs, "component_policy")
    end
  end
end
