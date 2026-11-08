# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.Session do
  @moduledoc """
  Ecto schema for the `sessions` table (backs `Arca.SessionStorage`).
  A session an account's key signed for records that key's `kid` and the
  account head it was verified under. A protected device's unlock
  records its paired `client_id`: that session's expiry is the device
  channel's. A browser's sign-in records its `browser` and `system` in
  words, and `last_seen_at` moves at most once a minute while the session
  is used.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "sessions" do
    field :token_hash, :binary
    field :token_prefix, :string
    field :user_id, :string
    field :email, :string
    field :provider, :string
    field :expires_at, :utc_datetime_usec
    field :athanor_id, :string
    # The key that signed for the session and the account head it was
    # verified under: both set, or both nil for a session no key signed.
    field :kid, :string
    field :head, :string
    # The protected device whose unlock created the session; nil for
    # every other session.
    field :client_id, :string
    field :browser, :string
    field :system, :string
    field :last_seen_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
