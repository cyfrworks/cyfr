defmodule Arca.TinctureData.QueryRunnerTest do
  use ExUnit.Case, async: false

  alias Arca.TinctureData.{QueryRunner, DB, Schema, Migrator, QueryCache}
  alias Sanctum.Context

  @ctx Context.build(org_id: "", project_id: "default", authenticated: false)

  setup do
    dir = Path.join(System.tmp_dir!(), "query_runner_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    manifest = %{
      "schema" => %{
        "tables" => %{
          "stocks" => %{
            "columns" => [
              %{"name" => "symbol", "type" => "TEXT", "not_null" => true},
              %{"name" => "date", "type" => "TEXT", "not_null" => true},
              %{"name" => "price", "type" => "REAL"}
            ],
            "primary_key" => ["symbol", "date"]
          }
        },
        "queries" => %{
          "latest" => %{
            "sql" => "SELECT * FROM stocks WHERE date = (SELECT MAX(date) FROM stocks)",
            "params" => %{},
            "cache_ttl" => 300
          },
          "by_symbol" => %{
            "sql" => "SELECT * FROM stocks WHERE symbol = :symbol ORDER BY date DESC",
            "params" => %{"symbol" => %{"type" => "text", "required" => true}},
            "cache_ttl" => 60
          }
        }
      }
    }

    # Set up database with test data
    :ok = Migrator.ensure_migrated(dir, manifest)

    db_path = DB.db_path(dir)

    {:ok, _} =
      DB.with_connection(db_path, :readwrite, fn conn ->
        DB.execute(conn, "INSERT INTO stocks VALUES (?, ?, ?)", ["AAPL", "2024-01-01", 150.0])
        DB.execute(conn, "INSERT INTO stocks VALUES (?, ?, ?)", ["AAPL", "2024-01-02", 152.0])
        DB.execute(conn, "INSERT INTO stocks VALUES (?, ?, ?)", ["GOOG", "2024-01-01", 140.0])
      end)

    {:ok, schema} = Schema.parse_manifest_schema(manifest)

    tincture = %{
      name: "test-dash",
      publisher: "local",
      dir: dir,
      manifest: manifest
    }

    on_exit(fn ->
      QueryCache.invalidate_tincture(@ctx, "local", "test-dash")
      File.rm_rf!(dir)
    end)

    %{tincture: tincture, schema: schema}
  end

  describe "execute/5" do
    test "executes query and returns data", %{tincture: t, schema: s} do
      query_def = s.queries["latest"]

      assert {:ok, result} = QueryRunner.execute(@ctx, t, "latest", query_def, %{})
      assert is_list(result.data)
      assert result.cached == false
      # MAX(date) is 2024-01-02, only AAPL has that date
      assert length(result.data) == 1
      assert hd(result.data)["symbol"] == "AAPL"
    end

    test "executes parameterized query", %{tincture: t, schema: s} do
      query_def = s.queries["by_symbol"]

      assert {:ok, result} =
               QueryRunner.execute(@ctx, t, "by_symbol", query_def, %{"symbol" => "AAPL"})

      assert length(result.data) == 2
      assert Enum.all?(result.data, fn row -> row["symbol"] == "AAPL" end)
    end

    test "returns cached result on second call", %{tincture: t, schema: s} do
      query_def = s.queries["latest"]

      {:ok, _} = QueryRunner.execute(@ctx, t, "latest", query_def, %{})
      {:ok, result2} = QueryRunner.execute(@ctx, t, "latest", query_def, %{})

      assert result2.cached == true
    end

    test "cache invalidation forces re-query", %{tincture: t, schema: s} do
      query_def = s.queries["latest"]

      {:ok, _} = QueryRunner.execute(@ctx, t, "latest", query_def, %{})
      QueryRunner.invalidate_tincture_cache(@ctx, "local", "test-dash")
      {:ok, result} = QueryRunner.execute(@ctx, t, "latest", query_def, %{})

      assert result.cached == false
    end
  end
end
