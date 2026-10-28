# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.CompanyAuthorization do
  @moduledoc """
  Ecto schema for the `company_authorizations` table (backs
  `Arca.CompanyAuthorizations`): a person's company sign-in, keyed by the
  person.
  """

  use Ecto.Schema

  @primary_key {:user_id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "company_authorizations" do
    field :configuration, :string
    field :subject, :string
    field :authorized_at, :utc_datetime_usec
  end
end
