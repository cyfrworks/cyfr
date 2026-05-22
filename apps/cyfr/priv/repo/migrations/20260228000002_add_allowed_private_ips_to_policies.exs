# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddAllowedPrivateIpsToPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add :allowed_private_ips, :text, default: "[]"
    end
  end
end
