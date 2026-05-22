# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddDigestIndexToComponents do
  use Ecto.Migration

  def change do
    create index(:components, [:digest])
  end
end
