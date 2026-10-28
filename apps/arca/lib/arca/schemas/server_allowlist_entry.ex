# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ServerAllowlistEntry do
  @moduledoc """
  One entry of the server allowlist — the door.

  An allow names a person identifier (`"identifier"`, `per_…`) or the
  wildcard (`"wildcard"`, whose `value` is `"*"`); a deny names a person of
  this server (`"person"`, their `usr_…` id) or a person identifier
  (`kinds/1`, `server_allowlist_kind_known`). `effect` is `"allow"` or
  `"deny"`; `status` is `"allowed"` for entries in force and `"requested"`
  for identifier allows a sign-in or an invitation asked for, pending a
  platform admin's decision. `label` is the handle an identifier entry was
  made from, a display label beside the identifier and never what admits
  anyone. Managed by `Sanctum.Door.Store`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @kinds %{"allow" => ["identifier", "wildcard"], "deny" => ["person", "identifier"]}
  @effects ["allow", "deny"]
  @statuses ["allowed", "requested"]

  @type t :: %__MODULE__{}

  schema "server_allowlist" do
    field :kind, :string
    field :value, :string
    field :effect, :string, default: "allow"
    field :status, :string, default: "allowed"
    field :requested_by, :string
    field :added_by, :string
    field :note, :string
    field :label, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @doc "Every kind an entry may name, either effect."
  def kinds, do: @kinds |> Map.values() |> List.flatten() |> Enum.uniq()

  @doc "The kinds an entry of `effect` may name."
  def kinds(effect), do: Map.get(@kinds, effect, [])
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
      :label,
      :created_at,
      :updated_at
    ])
    |> validate_required([:id, :kind, :value, :effect, :status])
    |> validate_inclusion(:effect, @effects)
    |> validate_kind()
    |> validate_inclusion(:status, @statuses)
    |> validate_value()
    |> validate_label()
    |> unique_constraint([:kind, :value])
  end

  defp validate_kind(changeset) do
    effect = get_field(changeset, :effect)

    if get_field(changeset, :kind) in kinds(effect),
      do: changeset,
      else: add_error(changeset, :kind, "is not a kind an #{effect} entry names")
  end

  # A wildcard is spelled one way; a person id and an identifier each have
  # exactly one spelling, which is checked, never changed.
  defp validate_value(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :value)} do
      {"wildcard", "*"} ->
        changeset

      {"wildcard", _} ->
        add_error(changeset, :value, "a wildcard entry's value is *")

      {"person", v} ->
        if Prima.PersonId.person?(v),
          do: changeset,
          else: add_error(changeset, :value, "is not a person's id")

      {"identifier", v} ->
        if Prima.Identity.Encoding.identifier?(v),
          do: changeset,
          else: add_error(changeset, :value, "is not a person identifier")

      _ ->
        changeset
    end
  end

  # A handle resolves to an identifier, so only an identifier entry is made
  # from one, and a label is spelled as the handle it was.
  defp validate_label(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :label)} do
      {_kind, nil} ->
        changeset

      {"identifier", label} ->
        if Prima.ComponentRef.valid_personal_slug?(label),
          do: changeset,
          else: add_error(changeset, :label, "is not a handle")

      _ ->
        add_error(changeset, :label, "only an identifier entry is made from a handle")
    end
  end
end
