defmodule Arca.TinctureData.SchemaTest do
  use ExUnit.Case, async: true

  alias Arca.TinctureData.Schema

  # ============================================================================
  # parse_manifest_schema/1
  # ============================================================================

  describe "parse_manifest_schema/1" do
    test "parses valid manifest with tables and queries" do
      manifest = stock_manifest()
      assert {:ok, schema} = Schema.parse_manifest_schema(manifest)
      assert Map.has_key?(schema.tables, "stocks")
      assert Map.has_key?(schema.queries, "latest")
      assert Map.has_key?(schema.queries, "stocks_by_date")
    end

    test "handles empty schema" do
      assert {:ok, schema} = Schema.parse_manifest_schema(%{})
      assert schema.tables == %{}
      assert schema.queries == %{}
    end

    test "rejects non-map manifest" do
      assert {:error, _} = Schema.parse_manifest_schema("not a map")
    end

    test "rejects unknown column type" do
      manifest = %{
        "schema" => %{
          "tables" => %{
            "t" => %{
              "columns" => [%{"name" => "x", "type" => "BIGINT"}],
              "primary_key" => []
            }
          }
        }
      }

      assert {:error, msg} = Schema.parse_manifest_schema(manifest)
      assert msg =~ "unknown column type"
    end

    test "rejects primary key referencing non-existent column" do
      manifest = %{
        "schema" => %{
          "tables" => %{
            "t" => %{
              "columns" => [%{"name" => "x", "type" => "TEXT"}],
              "primary_key" => ["x", "missing"]
            }
          }
        }
      }

      assert {:error, msg} = Schema.parse_manifest_schema(manifest)
      assert msg =~ "missing"
    end

    test "rejects query referencing undeclared params" do
      manifest = %{
        "schema" => %{
          "tables" => %{},
          "queries" => %{
            "q" => %{
              "sql" => "SELECT * FROM t WHERE x = :undeclared",
              "params" => %{}
            }
          }
        }
      }

      assert {:error, msg} = Schema.parse_manifest_schema(manifest)
      assert msg =~ "undeclared params"
    end
  end

  # ============================================================================
  # validate_row/2
  # ============================================================================

  describe "validate_row/2" do
    setup do
      table_schema = %{
        columns: [
          %{name: "symbol", type: :text, not_null: true},
          %{name: "date", type: :text, not_null: true},
          %{name: "price", type: :real, not_null: false},
          %{name: "volume", type: :integer, not_null: false}
        ],
        primary_key: ["symbol", "date"]
      }

      %{schema: table_schema}
    end

    test "accepts valid row", %{schema: s} do
      row = %{"symbol" => "AAPL", "date" => "2024-01-01", "price" => 150.0, "volume" => 1000}
      assert {:ok, coerced} = Schema.validate_row(s, row)
      assert coerced["symbol"] == "AAPL"
      assert coerced["price"] == 150.0
    end

    test "coerces integer to real", %{schema: s} do
      row = %{"symbol" => "AAPL", "date" => "2024-01-01", "price" => 150}
      assert {:ok, coerced} = Schema.validate_row(s, row)
      assert coerced["price"] == 150.0
    end

    test "rejects unknown columns", %{schema: s} do
      row = %{"symbol" => "AAPL", "date" => "2024-01-01", "unknown" => "x"}
      assert {:error, msg} = Schema.validate_row(s, row)
      assert msg =~ "unknown column"
    end

    test "rejects missing NOT NULL columns", %{schema: s} do
      row = %{"symbol" => "AAPL"}
      assert {:error, msg} = Schema.validate_row(s, row)
      assert msg =~ "cannot be null"
    end

    test "rejects missing primary key columns", %{schema: s} do
      row = %{"symbol" => "AAPL", "price" => 100.0}
      assert {:error, msg} = Schema.validate_row(s, row)
      assert msg =~ "cannot be null"
    end

    test "allows nil for optional columns", %{schema: s} do
      row = %{"symbol" => "AAPL", "date" => "2024-01-01", "volume" => nil}
      assert {:ok, _} = Schema.validate_row(s, row)
    end
  end

  # ============================================================================
  # generate_ddl/2
  # ============================================================================

  describe "generate_ddl/2" do
    test "generates CREATE TABLE with composite primary key" do
      table_schema = %{
        columns: [
          %{name: "symbol", type: :text, not_null: true},
          %{name: "date", type: :text, not_null: true},
          %{name: "price", type: :real, not_null: false}
        ],
        primary_key: ["symbol", "date"]
      }

      ddl = Schema.generate_ddl("stocks", table_schema)
      assert ddl =~ ~s(CREATE TABLE IF NOT EXISTS "stocks")
      assert ddl =~ ~s("symbol" TEXT NOT NULL)
      assert ddl =~ ~s("date" TEXT NOT NULL)
      assert ddl =~ ~s("price" REAL)
      assert ddl =~ ~s[PRIMARY KEY ("symbol", "date")]
    end

    test "generates DDL with no primary key" do
      table_schema = %{
        columns: [%{name: "val", type: :integer, not_null: false}],
        primary_key: []
      }

      ddl = Schema.generate_ddl("simple", table_schema)
      assert ddl =~ ~s(CREATE TABLE IF NOT EXISTS "simple")
      refute ddl =~ "PRIMARY KEY"
    end
  end

  # ============================================================================
  # prepare_query/2
  # ============================================================================

  describe "prepare_query/2" do
    test "converts named params to positional" do
      query_def = %{
        positional_sql: "SELECT * FROM stocks WHERE date = ? AND symbol = ?",
        param_order: ["date", "symbol"],
        params: %{
          "date" => %{type: :text, required: true, default: nil},
          "symbol" => %{type: :text, required: true, default: nil}
        }
      }

      assert {:ok, sql, values} =
               Schema.prepare_query(query_def, %{"date" => "2024-01-01", "symbol" => "AAPL"})

      assert sql == "SELECT * FROM stocks WHERE date = ? AND symbol = ?"
      assert values == ["2024-01-01", "AAPL"]
    end

    test "applies defaults for missing optional params" do
      query_def = %{
        positional_sql: "SELECT * FROM stocks LIMIT ?",
        param_order: ["limit"],
        params: %{
          "limit" => %{type: :integer, required: false, default: 30}
        }
      }

      assert {:ok, _sql, [30]} = Schema.prepare_query(query_def, %{})
    end

    test "rejects missing required params" do
      query_def = %{
        positional_sql: "SELECT * FROM stocks WHERE symbol = ?",
        param_order: ["symbol"],
        params: %{
          "symbol" => %{type: :text, required: true, default: nil}
        }
      }

      assert {:error, msg} = Schema.prepare_query(query_def, %{})
      assert msg =~ "required param 'symbol'"
    end
  end

  # ============================================================================
  # validate_query_sql/1 — Happy paths
  # ============================================================================

  describe "validate_query_sql/1 happy paths" do
    test "accepts simple SELECT" do
      assert {:ok, _} = Schema.validate_query_sql("SELECT * FROM stocks")
    end

    test "accepts SELECT with WHERE" do
      assert {:ok, _} = Schema.validate_query_sql("SELECT * FROM stocks WHERE date = :date")
    end

    test "accepts SELECT with JOIN" do
      sql = "SELECT s.*, p.name FROM stocks s JOIN portfolios p ON s.symbol = p.symbol"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "accepts non-recursive CTE" do
      sql = "WITH recent AS (SELECT * FROM stocks WHERE date > :since) SELECT * FROM recent"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "accepts subqueries" do
      sql = "SELECT * FROM stocks WHERE date = (SELECT MAX(date) FROM stocks)"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "accepts aggregate functions" do
      sql = "SELECT symbol, COUNT(*), AVG(price) FROM stocks GROUP BY symbol"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "accepts CASE expressions" do
      sql = "SELECT symbol, CASE WHEN price > 100 THEN 'high' ELSE 'low' END FROM stocks"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "allows trailing semicolon" do
      assert {:ok, _} = Schema.validate_query_sql("SELECT 1;")
    end

    test "extracts named params" do
      assert {:ok, result} = Schema.validate_query_sql("SELECT * FROM t WHERE a = :foo AND b = :bar")
      assert result.positional_sql == "SELECT * FROM t WHERE a = ? AND b = ?"
      assert result.param_order == ["foo", "bar"]
    end

    test "deduplicates params preserving first-occurrence order" do
      assert {:ok, result} =
               Schema.validate_query_sql("SELECT * FROM t WHERE a = :x AND b = :y AND c = :x")

      assert result.param_order == ["x", "y"]
    end
  end

  # ============================================================================
  # validate_query_sql/1 — Denied SQL patterns
  # ============================================================================

  describe "validate_query_sql/1 denied patterns" do
    test "rejects INSERT" do
      assert {:error, msg} = Schema.validate_query_sql("INSERT INTO stocks VALUES ('AAPL')")
      assert msg =~ "INSERT"
    end

    test "rejects UPDATE" do
      assert {:error, msg} = Schema.validate_query_sql("UPDATE stocks SET price = 100")
      assert msg =~ "UPDATE"
    end

    test "rejects DELETE" do
      assert {:error, msg} = Schema.validate_query_sql("DELETE FROM stocks")
      assert msg =~ "DELETE"
    end

    test "rejects DROP TABLE" do
      assert {:error, msg} = Schema.validate_query_sql("DROP TABLE stocks")
      assert msg =~ "DROP"
    end

    test "rejects CREATE TABLE" do
      assert {:error, msg} = Schema.validate_query_sql("CREATE TABLE evil (id INTEGER)")
      assert msg =~ "CREATE"
    end

    test "rejects ALTER TABLE" do
      assert {:error, msg} = Schema.validate_query_sql("ALTER TABLE stocks ADD COLUMN x TEXT")
      assert msg =~ "ALTER"
    end

    test "rejects ATTACH DATABASE" do
      assert {:error, msg} = Schema.validate_query_sql("ATTACH DATABASE 'evil.db' AS evil")
      assert msg =~ "ATTACH"
    end

    test "rejects DETACH DATABASE" do
      assert {:error, msg} = Schema.validate_query_sql("DETACH DATABASE evil")
      assert msg =~ "DETACH"
    end

    test "rejects PRAGMA" do
      assert {:error, msg} = Schema.validate_query_sql("PRAGMA journal_mode=DELETE")
      assert msg =~ "PRAGMA"
    end

    test "rejects LOAD_EXTENSION" do
      assert {:error, msg} = Schema.validate_query_sql("SELECT LOAD_EXTENSION('/evil.so')")
      assert msg =~ "LOAD_EXTENSION"
    end

    test "rejects WITH RECURSIVE" do
      sql = "WITH RECURSIVE cnt(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM cnt WHERE x<10) SELECT x FROM cnt"
      assert {:error, msg} = Schema.validate_query_sql(sql)
      assert msg =~ "RECURSIVE"
    end

    test "rejects multi-statement with semicolon" do
      assert {:error, msg} = Schema.validate_query_sql("SELECT 1; DROP TABLE stocks")
      assert msg =~ "multi-statement" or msg =~ "semicolon" or msg =~ "DROP"
    end

    test "rejects VACUUM" do
      assert {:error, msg} = Schema.validate_query_sql("VACUUM")
      assert msg =~ "VACUUM"
    end

    test "rejects ANALYZE" do
      assert {:error, msg} = Schema.validate_query_sql("ANALYZE stocks")
      assert msg =~ "ANALYZE"
    end

    test "rejects SAVEPOINT" do
      assert {:error, msg} = Schema.validate_query_sql("SAVEPOINT sp1")
      assert msg =~ "SAVEPOINT"
    end

    test "rejects REINDEX" do
      assert {:error, msg} = Schema.validate_query_sql("REINDEX stocks")
      assert msg =~ "REINDEX"
    end
  end

  # ============================================================================
  # validate_query_sql/1 — Bypass attempts (security-critical)
  # ============================================================================

  describe "validate_query_sql/1 bypass attempts" do
    test "rejects keyword hidden in block comment" do
      sql = "SELECT /* ATTACH */ 1"
      # After comment stripping, this becomes "SELECT   1" which is valid
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "rejects keyword after line comment" do
      sql = "SELECT 1 -- ATTACH DATABASE 'evil.db'"
      # After comment stripping, this becomes "SELECT 1  " which is valid
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "allows keywords inside string literals" do
      sql = "SELECT 'ATTACH' AS word"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "allows keywords inside double-quoted identifiers" do
      sql = ~s(SELECT "ATTACH" FROM t)
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "case-insensitive denylist" do
      assert {:error, _} = Schema.validate_query_sql("select attach from t")
      assert {:error, _} = Schema.validate_query_sql("SELECT AtTaCh FROM t")
      assert {:error, _} = Schema.validate_query_sql("SELECT pragma FROM t")
    end

    test "semicolons inside strings are allowed" do
      sql = "SELECT 'a;b' AS val"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "rejects non-ASCII outside string literals (homoglyph defense)" do
      # Cyrillic A (U+0410) looks like Latin A
      sql = "SELECT \u0410TTACH FROM t"
      assert {:error, msg} = Schema.validate_query_sql(sql)
      assert msg =~ "non-ASCII"
    end

    test "allows non-ASCII inside string literals" do
      sql = "SELECT '\u0410hello' AS val"
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end

    test "rejects unclosed block comment" do
      sql = "SELECT /* unclosed 1"
      assert {:error, msg} = Schema.validate_query_sql(sql)
      assert msg =~ "unclosed block comment"
    end

    test "rejects SELECT with embedded ATTACH in subquery" do
      sql = "SELECT * FROM (SELECT ATTACH FROM t)"
      assert {:error, _} = Schema.validate_query_sql(sql)
    end

    test "rejects ATTACH regardless of position in query" do
      sql = "SELECT * FROM t WHERE x IN (SELECT ATTACH FROM t2)"
      assert {:error, _} = Schema.validate_query_sql(sql)
    end

    test "params inside string literals are not extracted" do
      assert {:ok, result} = Schema.validate_query_sql("SELECT ':not_a_param' AS val")
      assert result.param_order == []
      assert result.positional_sql == "SELECT ':not_a_param' AS val"
    end
  end

  # ============================================================================
  # validate_query_sql/1 — Edge cases
  # ============================================================================

  describe "validate_query_sql/1 edge cases" do
    test "rejects empty SQL" do
      assert {:error, _} = Schema.validate_query_sql("")
    end

    test "rejects whitespace-only SQL" do
      assert {:error, _} = Schema.validate_query_sql("   \n  ")
    end

    test "rejects SQL with only comments" do
      assert {:error, _} = Schema.validate_query_sql("-- just a comment")
    end

    test "rejects non-string input" do
      assert {:error, _} = Schema.validate_query_sql(42)
    end

    test "handles SQL starting with parenthesized subquery" do
      sql = "(SELECT 1)"
      # First keyword after ( should be SELECT
      assert {:ok, _} = Schema.validate_query_sql(sql)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp stock_manifest do
    %{
      "schema" => %{
        "tables" => %{
          "stocks" => %{
            "columns" => [
              %{"name" => "symbol", "type" => "TEXT", "not_null" => true},
              %{"name" => "date", "type" => "TEXT", "not_null" => true},
              %{"name" => "price", "type" => "REAL"},
              %{"name" => "volume", "type" => "INTEGER"}
            ],
            "primary_key" => ["symbol", "date"]
          }
        },
        "queries" => %{
          "stocks_by_date" => %{
            "sql" => "SELECT * FROM stocks WHERE date = :date ORDER BY symbol",
            "params" => %{"date" => %{"type" => "text", "required" => true}},
            "cache_ttl" => 300
          },
          "latest" => %{
            "sql" => "SELECT * FROM stocks WHERE date = (SELECT MAX(date) FROM stocks)",
            "params" => %{},
            "cache_ttl" => 600
          }
        }
      }
    }
  end
end
