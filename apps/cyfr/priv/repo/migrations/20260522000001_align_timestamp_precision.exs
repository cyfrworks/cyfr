# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AlignTimestampPrecision do
  use Ecto.Migration

  # Four tables were created with the default `timestamps()` (second-precision
  # `timestamp`); every other table uses `:utc_datetime_usec`. Widen these to
  # microsecond precision so timestamps are uniformly `%DateTime{}` with the same
  # resolution on both adapters. This matters only on Postgres, which physically
  # distinguishes `timestamp(0)` from `timestamp(6)`; SQLite is dynamically typed,
  # so the Ecto field type alone governs read/write there.
  @tables [:components, :mcp_servers, :oauth_credentials, :component_dependencies]

  def up do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      for t <- @tables do
        alter table(t) do
          modify :inserted_at, :utc_datetime_usec
          modify :updated_at, :utc_datetime_usec
        end
      end
    end
  end

  def down do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      for t <- @tables do
        alter table(t) do
          modify :inserted_at, :naive_datetime
          modify :updated_at, :naive_datetime
        end
      end
    end
  end
end
