# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.StoreRefusal do
  @moduledoc """
  The store refusing one kind of write, for a test of what a write that
  was not kept does: a trigger refuses an insert into, or an update of, a
  table's row whose every named column holds its value. The trigger and
  its function are transactional test state, gone with the test's
  sandbox.
  """

  @typedoc "Columns and the values that make a row's write refused."
  @type columns :: [{String.t(), String.t()}]

  @doc "The store refuses an insert into `table` of a row that holds `columns`."
  @spec refuse_insert!(String.t(), columns()) :: :ok
  def refuse_insert!(table, columns), do: refuse!("insert", table, columns)

  @doc "The store refuses an update of `table` that leaves a row holding `columns`."
  @spec refuse_update!(String.t(), columns()) :: :ok
  def refuse_update!(table, columns), do: refuse!("update", table, columns)

  defp refuse!(write, table, columns) when columns != [] do
    name = "test_#{write}_refusal"
    event = String.upcase(write)

    holds =
      Enum.map_join(columns, " AND ", fn {column, value} -> "NEW.#{column} = '#{value}'" end)

    statements = %{
      Ecto.Adapters.Postgres => [
        """
        CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF #{holds} THEN RAISE EXCEPTION 'test #{write} refused'; END IF;
          RETURN NEW;
        END $$
        """,
        """
        CREATE TRIGGER #{name} BEFORE #{event} ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{name}()
        """
      ],
      Ecto.Adapters.SQLite3 => [
        """
        CREATE TRIGGER #{name} BEFORE #{event} ON #{table}
        WHEN #{holds}
        BEGIN SELECT RAISE(ABORT, 'test #{write} refused'); END
        """
      ]
    }

    statements |> Map.fetch!(Arca.Repo.__adapter__()) |> Enum.each(&Arca.Repo.query!/1)
  end
end
