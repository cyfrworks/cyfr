defmodule Arca.Repo.Migrations.DenyByDefaultMethodsAndActions do
  use Ecto.Migration

  @doc """
  Makes allowed_methods and allowed_actions deny-by-default (empty list)
  to match the existing behavior of allowed_domains and allowed_paths.

  - Sets allowed_methods to "[]" where allowed_domains is "[]"
    (no HTTP access = methods irrelevant)
  - Sets allowed_actions to "[]" where allowed_paths is "[]"
    (no storage access = actions irrelevant)

  Column defaults are handled in application code (Policy struct and PolicyStore).
  """

  def up do
    # Clear methods for components with no HTTP domains configured
    execute("""
    UPDATE policies
    SET allowed_methods = '[]', updated_at = datetime('now')
    WHERE allowed_domains = '[]'
      AND allowed_methods != '[]'
    """)

    # Clear actions for components with no storage paths configured
    execute("""
    UPDATE policies
    SET allowed_actions = '[]', updated_at = datetime('now')
    WHERE allowed_paths = '[]'
      AND allowed_actions != '[]'
    """)
  end

  def down do
    # Restore allow-all defaults for methods where domains are empty
    execute("""
    UPDATE policies
    SET allowed_methods = '["GET","POST","PUT","DELETE","PATCH"]', updated_at = datetime('now')
    WHERE allowed_domains = '[]'
      AND allowed_methods = '[]'
    """)

    # Restore allow-all defaults for actions where paths are empty
    execute("""
    UPDATE policies
    SET allowed_actions = '["read","write","list","delete","exists"]', updated_at = datetime('now')
    WHERE allowed_paths = '[]'
      AND allowed_actions = '[]'
    """)
  end
end
