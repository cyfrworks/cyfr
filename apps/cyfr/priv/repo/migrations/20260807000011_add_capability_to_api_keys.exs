# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddCapabilityToApiKeys do
  use Ecto.Migration

  # The scoped-automation consent capability: string-JSON like scope and
  # ip_allowlist. Nullable — almost every key carries none, and a key
  # without one can never commit a consent.
  def change do
    alter table(:api_keys) do
      add :capability, :text
    end
  end
end
