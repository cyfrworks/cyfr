defmodule Arca.Repo.Migrations.NormalizeComponentRefs do
  use Ecto.Migration

  @tables_with_component_ref [:policies, :secret_grants, :component_configs, :policy_logs]

  def up do
    for table <- @tables_with_component_ref do
      # Delete old-format rows where a new-format equivalent already exists,
      # to avoid UNIQUE constraint violations during the UPDATE passes below.
      execute("""
      DELETE FROM #{table}
      WHERE component_ref LIKE 'local:%:%'
        AND component_ref NOT LIKE 'local.%'
        AND 'local.' || SUBSTR(component_ref, 7) IN (
          SELECT component_ref FROM #{table} WHERE component_ref LIKE 'local.%'
        )
      """)

      execute("""
      DELETE FROM #{table}
      WHERE component_ref LIKE '%:%'
        AND component_ref NOT LIKE '%.%:%'
        AND component_ref NOT LIKE 'local.%'
        AND 'local.' || component_ref IN (
          SELECT component_ref FROM #{table} WHERE component_ref LIKE 'local.%'
        )
      """)

      # Pass 1: Convert legacy "local:name:version" → "local.name:version"
      # SUBSTR(component_ref, 7) strips the "local:" prefix (6 chars), then we prepend "local."
      execute("""
      UPDATE #{table}
      SET component_ref = 'local.' || SUBSTR(component_ref, 7)
      WHERE component_ref LIKE 'local:%:%'
        AND component_ref NOT LIKE 'local.%'
      """)

      # Pass 2: Convert bare "name:version" → "local.name:version"
      # Matches refs that contain a colon but have no dot before the colon
      execute("""
      UPDATE #{table}
      SET component_ref = 'local.' || component_ref
      WHERE component_ref LIKE '%:%'
        AND component_ref NOT LIKE '%.%:%'
        AND component_ref NOT LIKE 'local.%'
      """)
    end
  end

  def down do
    # Reverse: strip "local." prefix where it was added
    # This is best-effort — we cannot distinguish refs that were already canonical
    # from those we migrated, so we only reverse "local." namespace refs
    for table <- @tables_with_component_ref do
      execute("""
      UPDATE #{table}
      SET component_ref = SUBSTR(component_ref, 7)
      WHERE component_ref LIKE 'local.%'
      """)
    end
  end
end
