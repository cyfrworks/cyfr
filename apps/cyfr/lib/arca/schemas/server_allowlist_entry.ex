# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ServerAllowlistEntry do
  @moduledoc """
  One entry of the server allowlist — the door.

  `kind` is `"email"`, `"user_id"` (an IdP subject) or `"wildcard"` (whose
  `value` is `"*"`); `effect` is `"allow"` or `"deny"`; `status` is
  `"allowed"` for entries in force and `"requested"` for allow entries a
  member asked for by inviting an address the door does not know, pending a
  platform admin's decision. Managed by `Sanctum.Door.Store`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @kinds ["email", "user_id", "wildcard"]
  @effects ["allow", "deny"]
  @statuses ["allowed", "requested"]

  schema "server_allowlist" do
    field :kind, :string
    field :value, :string
    field :effect, :string, default: "allow"
    field :status, :string, default: "allowed"
    field :requested_by, :string
    field :added_by, :string
    field :note, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def kinds, do: @kinds
  def effects, do: @effects
  def statuses, do: @statuses

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :id,
      :kind,
      :value,
      :effect,
      :status,
      :requested_by,
      :added_by,
      :note,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :kind, :value, :effect, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:effect, @effects)
    |> validate_inclusion(:status, @statuses)
    |> validate_value()
    |> unique_constraint([:kind, :value])
  end

  # A wildcard is spelled one way; an email is stored lowercased so the door
  # matches what the provider asserts regardless of how it was typed.
  defp validate_value(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :value)} do
      {"wildcard", "*"} -> changeset
      {"wildcard", _} -> add_error(changeset, :value, "a wildcard entry's value is *")
      {"email", v} when is_binary(v) -> put_change(changeset, :value, String.downcase(v))
      _ -> changeset
    end
  end
end
