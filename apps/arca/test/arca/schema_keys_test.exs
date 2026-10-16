# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SchemaKeysTest do
  @moduledoc """
  Every primary-key column of every table is NOT NULL on the active
  adapter, read from the live catalog.

  PostgreSQL makes a primary-key column NOT NULL whatever the migration
  says; SQLite does not, and admits NULL in any key column it was not told
  is NOT NULL, so two rows with the same NULL key both land. A key column
  the baseline declares without `null: false` is a key on one adapter and
  not on the other. The one exception SQLite itself guarantees is a
  table's single `INTEGER PRIMARY KEY`, which aliases the rowid and is
  never NULL.
  """

  use ExUnit.Case, async: true

  import Arca.Test.Adapter, only: [sqlite?: 0]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    :ok
  end

  test "every primary-key column of every table is NOT NULL" do
    keys = key_columns()

    # The catalog answered: an empty read is never a pass.
    assert Enum.any?(keys, &match?({"turns", "id", _}, &1))
    assert Enum.any?(keys, &match?({"cell_leases", "node", _}, &1))

    nullable = for {table, column, false} <- keys, do: "#{table}.#{column}"

    assert nullable == [],
           "These primary-key columns admit NULL on this adapter; declare them null: false:\n  " <>
             Enum.join(nullable, "\n  ")
  end

  # `{table, column, not_null?}` for every primary-key column.
  defp key_columns do
    if sqlite?(), do: sqlite_keys(), else: postgres_keys()
  end

  defp sqlite_keys do
    %{rows: rows} =
      Arca.Repo.query!("""
      SELECT m.name, p.name, p.type, p."notnull", p.pk,
             (SELECT count(*) FROM pragma_table_info(m.name) q WHERE q.pk > 0)
      FROM sqlite_master m JOIN pragma_table_info(m.name) p
      WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND p.pk > 0
      ORDER BY m.name, p.pk
      """)

    for [table, column, type, not_null, _pk, key_width] <- rows do
      rowid? = key_width == 1 and String.upcase(type || "") == "INTEGER"
      {table, column, not_null == 1 or rowid?}
    end
  end

  defp postgres_keys do
    %{rows: rows} =
      Arca.Repo.query!("""
      SELECT c.relname, a.attname, a.attnotnull
      FROM pg_constraint k
      JOIN pg_class c ON c.oid = k.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (k.conkey)
      WHERE k.contype = 'p' AND n.nspname = current_schema()
      ORDER BY c.relname, a.attnum
      """)

    for [table, column, not_null] <- rows, do: {table, column, not_null}
  end
end
