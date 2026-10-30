# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Share do
  @moduledoc """
  One of an athanor's vault entries offered to an audience: `everyone`,
  or the active members of the group `group_id` names. A share holds no
  material and no name; it is the entry and the audience, and one active
  share per entry and audience is its natural key. `person_daily` and
  `total_daily` are its daily caps, each absent for no limit, `0` for no
  use or at most `max_cap/0`. Its status is `active` or `revoked`
  (`Arca.StatusTransitions`'s `:shares`), and a revoked share stays.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  # The caps are 32-bit integers on PostgreSQL; a larger one is refused
  # here on both adapters rather than by one driver alone.
  @max_cap 2_147_483_647
  @audiences ~w(everyone group)

  schema "shares" do
    field :athanor_id, :string
    field :vault_entry_id, :string
    field :audience, :string
    field :group_id, :string
    field :person_daily, :integer
    field :total_daily, :integer
    field :status, :string, default: "active"
    field :created_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The audiences a share may name."
  @spec audiences() :: [String.t()]
  def audiences, do: @audiences

  @doc "The largest daily cap a share holds."
  @spec max_cap() :: pos_integer()
  def max_cap, do: @max_cap

  @doc "Whether `cap` is a cap a share may hold: absent, or an integer from 0 to `max_cap/0`."
  @spec cap?(term()) :: boolean()
  def cap?(nil), do: true
  def cap?(cap), do: is_integer(cap) and cap >= 0 and cap <= @max_cap

  @doc """
  A new row: its athanor, entry and creator; an audience in the
  vocabulary with `group_id` exactly when it is `group`; each cap absent
  or within `max_cap/0`. The status is the column's `active`.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :athanor_id,
      :vault_entry_id,
      :audience,
      :group_id,
      :person_daily,
      :total_daily,
      :created_by
    ])
    |> validate_required([:id, :athanor_id, :vault_entry_id, :audience, :created_by])
    |> validate_audience()
    |> validate_caps()
  end

  @doc """
  An audience as a write names it, `%{audience: _, group_id: _}`, held to
  the same rule: `everyone` with no group, or `group` with one.
  """
  @spec audience_valid?(term()) :: boolean()
  def audience_valid?(%{audience: "everyone", group_id: nil}), do: true

  def audience_valid?(%{audience: "group", group_id: group_id}),
    do: is_binary(group_id) and group_id != ""

  def audience_valid?(_other), do: false

  defp validate_audience(changeset) do
    audience = %{
      audience: get_field(changeset, :audience),
      group_id: get_field(changeset, :group_id)
    }

    if audience_valid?(audience),
      do: changeset,
      else: add_error(changeset, :audience, "is everyone with no group, or group with one")
  end

  defp validate_caps(changeset) do
    Enum.reduce([:person_daily, :total_daily], changeset, fn field, acc ->
      if cap?(get_field(acc, field)),
        do: acc,
        else: add_error(acc, field, "is absent or an integer from 0 to #{@max_cap}")
    end)
  end
end
