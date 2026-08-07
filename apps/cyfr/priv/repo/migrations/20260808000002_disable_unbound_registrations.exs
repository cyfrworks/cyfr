# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Repo.Migrations.DisableUnboundRegistrations do
  use Ecto.Migration

  # A registration without a profile has no consent to run under. It used
  # to keep the legacy execution path; that path is gone, so unbound rows
  # flip to a disabled state the operator clears by binding a profile.
  # Cron reuses its status vocabulary (gaining "needs_consent"); webhooks
  # reuse their enabled flag.
  def up do
    execute("UPDATE webhooks SET enabled = FALSE WHERE profile_id IS NULL")

    execute(
      "UPDATE cron_schedules SET status = 'needs_consent' WHERE profile_id IS NULL AND status = 'active'"
    )
  end

  def down do
    # Deliberately irreversible: re-enabling every unbound registration
    # wholesale would resurrect attacker-timed invocation channels the
    # operator never re-consented. Bind a profile instead.
    :ok
  end
end
