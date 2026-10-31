# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.ConsentVaultRef do
  @moduledoc """
  One binding of a consent revision, written in the same transaction as
  the revision and keyed by `(consent_id, binding_key)`.

  `binding_key` is `<source node reference>|<edge key>|<slot>`; the row
  names exactly one of the athanor's own entry (`vault_entry_id`), a share
  of another athanor's entry (`share_id`, a bare id: the share is its
  owner's row), each with the binding digest it was approved at, or a
  selection (`via_label`), the label of the profile of the same athanor it
  borrows from, with the digest it pinned when it pinned one. Its scope is
  derived from the one it names (`scope/1`): `share` for a share,
  `athanor` for an entry or a selection. A selection's `athanor` scope
  says only that it is resolved within the borrowing consent's own
  athanor; it says nothing about the scope of the lender's entry, which
  the loader answers when it resolves the selection. It carries the
  binding's own lifetime: `lifetime_kind` `standing`, `until` (with
  `expires_at`) or `once`, and for a `once` binding the root execution it
  was consumed under (`consumed_by_root`). No surrogate id: rows are
  queried by consent, key or entry. The rules are `changeset/1`'s and,
  beneath it, the baseline's checks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @type t :: %__MODULE__{}

  @lifetimes ~w(standing until once)

  schema "consent_vault_refs" do
    field :consent_id, :string
    field :athanor_id, :string
    field :binding_key, :string
    field :vault_entry_id, :string
    field :share_id, :string
    field :via_label, :string
    field :binding_digest, :string
    field :lifetime_kind, :string, default: "standing"
    field :expires_at, :utc_datetime_usec
    field :consumed_by_root, :string
  end

  @doc """
  The scope of a binding, a row or a ref map naming one: `"share"` when it
  names a share (`share_id` set), `"athanor"` otherwise, an entry of the
  athanor's own or a selection resolved within it.
  """
  @spec scope(map()) :: String.t()
  def scope(%{share_id: share_id}) when is_binary(share_id) and share_id != "", do: "share"
  def scope(%{}), do: "athanor"

  @doc """
  A new row held to the binding rules: a key, a consent and an athanor;
  exactly one of `vault_entry_id`, `share_id` and `via_label`; a digest
  for an entry or a share; a lifetime in the vocabulary, with
  `expires_at` exactly when it is `until`.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :consent_id,
      :athanor_id,
      :binding_key,
      :vault_entry_id,
      :share_id,
      :via_label,
      :binding_digest,
      :lifetime_kind,
      :expires_at,
      :consumed_by_root
    ])
    |> validate_required([:consent_id, :athanor_id, :binding_key, :lifetime_kind])
    |> validate_inclusion(:lifetime_kind, @lifetimes)
    |> validate_names_one()
    |> validate_lifetime()
  end

  defp validate_names_one(changeset) do
    named =
      for field <- [:vault_entry_id, :share_id, :via_label],
          present?(get_field(changeset, field)),
          do: field

    digest? = present?(get_field(changeset, :binding_digest))

    case named do
      [:via_label] ->
        changeset

      [_entry_or_share] when digest? ->
        changeset

      [_entry_or_share] ->
        add_error(changeset, :binding_digest, "names the digest its entry is bound at")

      _ ->
        add_error(changeset, :binding, "names exactly one of an entry, a share and a selection")
    end
  end

  defp validate_lifetime(changeset) do
    case {get_field(changeset, :lifetime_kind), get_field(changeset, :expires_at)} do
      {"until", %DateTime{}} -> changeset
      {"until", _none} -> add_error(changeset, :expires_at, "is required of an until lifetime")
      {_kind, nil} -> changeset
      {_kind, _at} -> add_error(changeset, :expires_at, "is only an until lifetime's")
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
