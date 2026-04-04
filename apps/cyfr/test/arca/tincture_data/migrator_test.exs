defmodule Arca.TinctureData.MigratorTest do
  use ExUnit.Case, async: true

  alias Arca.TinctureData.{Migrator, DB}

  setup do
    dir = Path.join(System.tmp_dir!(), "migrator_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  defp manifest_with_table(columns, pk \\ []) do
    %{
      "schema" => %{
        "tables" => %{
          "stocks" => %{
            "columns" => columns,
            "primary_key" => pk
          }
        },
        "queries" => %{}
      }
    }
  end

  describe "migrate/2" do
    test "creates new table from schema", %{dir: dir} do
      manifest =
        manifest_with_table(
          [
            %{"name" => "symbol", "type" => "TEXT", "not_null" => true},
            %{"name" => "date", "type" => "TEXT", "not_null" => true},
            %{"name" => "price", "type" => "REAL"}
          ],
          ["symbol", "date"]
        )

      assert {:ok, result} = Migrator.migrate(dir, manifest)
      assert "stocks" in result.tables_created

      # Verify table exists
      db_path = DB.db_path(dir)

      {:ok, query_result} =
        DB.with_connection(db_path, :readonly, fn conn ->
          DB.query(conn, "PRAGMA table_info(stocks)")
        end)

      assert {:ok, %{rows: rows}} = query_result
      col_names = Enum.map(rows, fn row -> Enum.at(row, 1) end)
      assert "symbol" in col_names
      assert "date" in col_names
      assert "price" in col_names
    end

    test "adds columns to existing table", %{dir: dir} do
      # First migration — two columns
      manifest1 =
        manifest_with_table([
          %{"name" => "symbol", "type" => "TEXT", "not_null" => true},
          %{"name" => "date", "type" => "TEXT", "not_null" => true}
        ])

      assert {:ok, _} = Migrator.migrate(dir, manifest1)

      # Second migration — add a column
      manifest2 =
        manifest_with_table([
          %{"name" => "symbol", "type" => "TEXT", "not_null" => true},
          %{"name" => "date", "type" => "TEXT", "not_null" => true},
          %{"name" => "volume", "type" => "INTEGER"}
        ])

      assert {:ok, result} = Migrator.migrate(dir, manifest2)
      assert {"stocks", "volume"} in result.columns_added
    end

    test "is idempotent — running twice produces same result", %{dir: dir} do
      manifest =
        manifest_with_table(
          [
            %{"name" => "id", "type" => "INTEGER"},
            %{"name" => "val", "type" => "TEXT"}
          ],
          ["id"]
        )

      assert {:ok, _} = Migrator.migrate(dir, manifest)
      assert {:ok, result2} = Migrator.migrate(dir, manifest)

      # No new tables or columns on second run
      assert result2.tables_created == []
      assert result2.columns_added == []
    end
  end

  describe "ensure_migrated/2" do
    test "succeeds and is idempotent", %{dir: dir} do
      manifest =
        manifest_with_table([
          %{"name" => "id", "type" => "INTEGER"}
        ])

      assert :ok = Migrator.ensure_migrated(dir, manifest)
      assert :ok = Migrator.ensure_migrated(dir, manifest)
    end
  end
end
