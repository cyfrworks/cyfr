# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddResolverDigestToExecutions do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :resolver_digest, :string
    end
  end
end
