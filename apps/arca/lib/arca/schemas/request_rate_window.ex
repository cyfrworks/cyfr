# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Schemas.RequestRateWindow do
  @moduledoc """
  Ecto schema for the `request_rate_windows` table (backs
  `Arca.RequestRateWindows`): one fixed window of a pre-authentication
  limit, per bucket and hashed key.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "request_rate_windows" do
    field :bucket, :string
    field :key_hash, :string
    field :window_start, :utc_datetime_usec
    field :window_ms, :integer
    field :count, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end
