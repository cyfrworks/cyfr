defmodule Arca.Repo.Migrations.AddResolvedReferenceToCronSchedules do
  use Ecto.Migration

  def change do
    alter table(:cron_schedules) do
      add :resolved_reference, :string
    end

    # Backfill: copy reference → resolved_reference for existing schedules.
    # Existing schedules already have explicit versions in reference.
    execute(
      "UPDATE cron_schedules SET resolved_reference = reference WHERE resolved_reference IS NULL",
      "UPDATE cron_schedules SET resolved_reference = NULL"
    )
  end
end
