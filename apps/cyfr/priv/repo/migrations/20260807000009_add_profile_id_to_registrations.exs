# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.AddProfileIdToRegistrations do
  use Ecto.Migration

  # A registration is a standing invocation conduit; binding it to a
  # profile decides whose consented authority every future firing carries.
  # Nullable: NULL runs the legacy path until the operator (or the upgrade
  # migration) binds one. No FK — profiles are tenant-partitioned by
  # (org_id, id) and both tables predate that pair; the binding gate and
  # the fail-closed selection at fire time are the guarantee.
  def change do
    alter table(:webhooks) do
      add :profile_id, :string
    end

    alter table(:cron_schedules) do
      add :profile_id, :string
    end
  end
end
