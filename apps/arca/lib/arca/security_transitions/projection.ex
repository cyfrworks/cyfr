# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SecurityTransitions.Projection do
  @moduledoc false
  # The plain maps a transition's or an issuance's `verify:` callback is
  # handed: the locked rows, field by field, and nothing that belongs to
  # Ecto. A callback decides on what these say and never receives a
  # changeset or a row it could write back.

  alias Arca.Schemas.{ApiKey, Athanor, Membership, Session, User}

  @spec user(User.t() | nil) :: map() | nil
  def user(nil), do: nil

  def user(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      email_verified: user.email_verified,
      status: user.status,
      denied_at: user.denied_at,
      personal_athanor_id: user.personal_athanor_id,
      security_generation: user.security_generation
    }
  end

  @spec athanor(Athanor.t() | nil) :: map() | nil
  def athanor(nil), do: nil

  def athanor(%Athanor{} = athanor) do
    %{
      id: athanor.id,
      kind: athanor.kind,
      roster: athanor.roster,
      name: athanor.name,
      owner_user_id: athanor.owner_user_id,
      created_by: athanor.created_by,
      status: athanor.status,
      archived_at: athanor.archived_at,
      security_generation: athanor.security_generation
    }
  end

  @spec membership(Membership.t() | nil) :: map() | nil
  def membership(nil), do: nil

  def membership(%Membership{} = membership) do
    %{
      id: membership.id,
      user_id: membership.user_id,
      email: membership.email,
      athanor_id: membership.athanor_id,
      scope: membership.scope,
      status: membership.status
    }
  end

  # The session row without its token hash: the hash is the lookup key the
  # caller already holds, and a callback has no use for it.
  @spec session(Session.t() | nil) :: map() | nil
  def session(nil), do: nil

  def session(%Session{} = session) do
    %{
      id: session.id,
      user_id: session.user_id,
      athanor_id: session.athanor_id,
      expires_at: session.expires_at
    }
  end

  @spec api_key(ApiKey.t() | nil) :: map() | nil
  def api_key(nil), do: nil

  def api_key(%ApiKey{} = key) do
    %{
      id: key.id,
      name: key.name,
      athanor_id: key.athanor_id,
      created_by: key.created_by,
      revoked: key.revoked
    }
  end
end
