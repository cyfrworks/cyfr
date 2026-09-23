# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions.Projection do
  @moduledoc false
  # The plain maps a transition's or an issuance's `verify:` callback is
  # handed: the locked rows projected (`Arca.Data`) and narrowed to the
  # fields a standing decision reads. A callback decides on what these say
  # and never receives a changeset, a row it could write back, or a
  # credential's hash — the session's token hash and a key's hash are the
  # lookup keys the caller already holds, and a callback has no use for
  # them.

  alias Arca.Schemas.{ApiKey, Athanor, Membership, Session, User}

  @user ~w(id email email_verified status denied_at personal_athanor_id security_generation)a
  @athanor ~w(id kind roster name owner_user_id created_by status archived_at security_generation)a
  @membership ~w(id user_id email athanor_id scope status)a
  @session ~w(id user_id athanor_id expires_at)a
  @api_key ~w(id name athanor_id created_by revoked ip_allowlist)a

  @spec user(User.t() | nil) :: map() | nil
  def user(row), do: narrowed(row, User, @user)

  @spec athanor(Athanor.t() | nil) :: map() | nil
  def athanor(row), do: narrowed(row, Athanor, @athanor)

  @spec membership(Membership.t() | nil) :: map() | nil
  def membership(row), do: narrowed(row, Membership, @membership)

  @spec session(Session.t() | nil) :: map() | nil
  def session(row), do: narrowed(row, Session, @session)

  @spec api_key(ApiKey.t() | nil) :: map() | nil
  def api_key(row), do: narrowed(row, ApiKey, @api_key)

  defp narrowed(nil, _schema, _fields), do: nil

  defp narrowed(%schema{} = row, schema, fields),
    do: row |> Arca.Data.project() |> Map.take(fields)
end
