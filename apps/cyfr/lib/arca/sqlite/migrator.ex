defmodule Arca.Sqlite.Migrator do
  @moduledoc """
  DDL migration for sandbox SQLite databases.

  Creates tables and adds new columns based on manifest schema declarations.
  Uses CREATE TABLE IF NOT EXISTS and PRAGMA table_info for idempotency.
  """

  alias Arca.{Sqlite, Sqlite.Schema}

  @doc """
  Run migration: create/alter tables to match the manifest schema.

  Returns `{:ok, %{tables_created: [...], columns_added: [{table, col}]}}`.
  """
  @spec migrate(String.t(), map()) ::
          {:ok, %{tables_created: [String.t()], columns_added: [{String.t(), String.t()}]}}
          | {:error, String.t()}
  def migrate(version_dir, manifest) do
    with {:ok, schema} <- Schema.parse_manifest_schema(manifest) do
      db_path = Sqlite.db_path(version_dir)
      dir = Path.dirname(db_path)
      File.mkdir_p!(dir)

      Sqlite.with_connection(db_path, :readwrite, fn conn ->
        {tables_created, columns_added} =
          Enum.reduce(schema.tables, {[], []}, fn {table_name, table_schema},
                                                   {created, added} ->
            # Check existing columns BEFORE creating the table
            existing_cols = get_existing_columns(conn, table_name)
            was_new = existing_cols == []

            ddl = Schema.generate_ddl(table_name, table_schema)
            :ok = Sqlite.execute(conn, ddl)

            new_created =
              if was_new do
                [table_name | created]
              else
                created
              end

            # Add missing columns (only for existing tables — new tables have all columns from DDL)
            # Re-read existing columns after CREATE to get the full list
            current_cols = if was_new, do: MapSet.new(table_schema.columns, & &1.name), else: MapSet.new(existing_cols)
            declared_names = MapSet.new(table_schema.columns, & &1.name)
            missing = MapSet.difference(declared_names, current_cols)

            new_added =
              if MapSet.size(missing) > 0 do
                Enum.reduce(table_schema.columns, added, fn col, acc ->
                  if MapSet.member?(missing, col.name) do
                    type_str =
                      case col.type do
                        :text -> "TEXT"
                        :integer -> "INTEGER"
                        :real -> "REAL"
                        :blob -> "BLOB"
                      end

                    # Note: NOT NULL is intentionally omitted on ALTER TABLE ADD COLUMN.
                    # SQLite rejects adding NOT NULL columns without DEFAULT to tables
                    # that already have rows. Application-level validation in Schema.validate_row
                    # still enforces NOT NULL on new writes.
                    alter_sql =
                      "ALTER TABLE #{Schema.quote_identifier(table_name)} ADD COLUMN #{Schema.quote_identifier(col.name)} #{type_str}"
                    :ok = Sqlite.execute(conn, alter_sql)
                    [{table_name, col.name} | acc]
                  else
                    acc
                  end
                end)
              else
                added
              end

            {new_created, new_added}
          end)

        %{tables_created: Enum.reverse(tables_created), columns_added: Enum.reverse(columns_added)}
      end)
    end
  end

  @doc """
  Ensure the database is migrated. Idempotent — safe to call repeatedly.
  """
  @spec ensure_migrated(String.t(), map()) :: :ok | {:error, String.t()}
  def ensure_migrated(version_dir, manifest) do
    case migrate(version_dir, manifest) do
      {:ok, _result} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp get_existing_columns(conn, table_name) do
    case Sqlite.query(conn, "PRAGMA table_info(#{Schema.quote_identifier(table_name)})") do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn row -> Enum.at(row, 1) end)

      _ ->
        []
    end
  end
end
