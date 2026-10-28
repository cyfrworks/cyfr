# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.CompanyLoginAttempt do
  @moduledoc """
  Ecto schema for the `company_login_attempts` table (backs
  `Arca.CompanyLoginAttempts`): one company sign-in in flight, stored by
  the hash of its state.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "company_login_attempts" do
    field :user_id, :string
    field :session_hash, :binary
    field :state_hash, :binary
    field :nonce, :string
    field :pkce_verifier, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
  end
end
