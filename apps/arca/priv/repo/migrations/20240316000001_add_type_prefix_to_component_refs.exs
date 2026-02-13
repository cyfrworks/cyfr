defmodule Arca.Repo.Migrations.AddTypePrefixToComponentRefs do
  use Ecto.Migration

  @moduledoc """
  Adds type prefix to all stored component refs.

  Before: `local.claude:0.1.0`
  After:  `catalyst:local.claude:0.1.0`

  Strategy:
  1. `policies` and `policy_logs` have their own `component_type` column — use it directly
  2. `secret_grants` and `component_configs` join against `components` table to look up type
  3. Orphaned refs (no matching component) in grants/configs are deleted as stale
  """

  @type_prefixed_tables [:policies, :secret_grants, :component_configs, :policy_logs]
  @known_type_prefixes ~w(catalyst reagent formula)

  def up do
    # Guard clause: skip refs that already have a type prefix
    not_typed = @known_type_prefixes
    |> Enum.map_join(" AND ", &"component_ref NOT LIKE '#{&1}:%'")

    # Step 1: policies and policy_logs have their own component_type column
    for table <- [:policies, :policy_logs] do
      execute("""
      UPDATE #{table}
      SET component_ref = component_type || ':' || component_ref
      WHERE #{not_typed}
        AND component_type IS NOT NULL
        AND component_type != ''
      """)
    end

    # Step 2: secret_grants and component_configs — join with components table
    for table <- [:secret_grants, :component_configs] do
      execute("""
      UPDATE #{table}
      SET component_ref = (
        SELECT c.component_type || ':' || #{table}.component_ref
        FROM components c
        WHERE #{table}.component_ref = c.publisher || '.' || c.name || ':' || c.version
        LIMIT 1
      )
      WHERE #{not_typed}
        AND EXISTS (
          SELECT 1 FROM components c
          WHERE #{table}.component_ref = c.publisher || '.' || c.name || ':' || c.version
        )
      """)
    end

    # Step 3: Delete orphaned refs that couldn't be resolved (stale data)
    for table <- [:secret_grants, :component_configs] do
      execute("""
      DELETE FROM #{table}
      WHERE #{not_typed}
      """)
    end
  end

  def down do
    # Strip type prefixes by removing "type:" from the front of each ref
    for table <- @type_prefixed_tables do
      for type <- @known_type_prefixes do
        prefix_len = String.length(type) + 2  # "catalyst:" = 10 chars
        execute("""
        UPDATE #{table}
        SET component_ref = SUBSTR(component_ref, #{prefix_len})
        WHERE component_ref LIKE '#{type}:%'
        """)
      end
    end
  end
end
