defmodule Arca.SqliteTest do
  use ExUnit.Case, async: true

  alias Arca.Sqlite

  setup do
    dir = Path.join(System.tmp_dir!(), "db_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    db_path = Path.join(dir, "test.db")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, db_path: db_path}
  end

  describe "with_connection/3" do
    test "opens, uses, and closes connection", %{db_path: db_path} do
      assert {:ok, :worked} =
               Sqlite.with_connection(db_path, :readwrite, fn conn ->
                 :ok = Sqlite.execute(conn, "CREATE TABLE t (id INTEGER)")
                 :worked
               end)

      # Verify table persists
      assert {:ok, result} =
               Sqlite.with_connection(db_path, :readonly, fn conn ->
                 Sqlite.query(conn, "SELECT name FROM sqlite_master WHERE type='table'")
               end)

      assert {:ok, %{rows: [["t"]]}} = result
    end

    test "readonly mode rejects writes", %{db_path: db_path} do
      # Create the DB first
      {:ok, _} =
        Sqlite.with_connection(db_path, :readwrite, fn conn ->
          Sqlite.execute(conn, "CREATE TABLE t (id INTEGER)")
        end)

      # Readonly should reject INSERT
      {:ok, result} =
        Sqlite.with_connection(db_path, :readonly, fn conn ->
          Sqlite.execute(conn, "INSERT INTO t VALUES (1)")
        end)

      assert {:error, _} = result
    end

    test "WAL mode is enabled", %{db_path: db_path} do
      {:ok, _} =
        Sqlite.with_connection(db_path, :readwrite, fn conn ->
          {:ok, %{rows: [[mode]]}} = Sqlite.query(conn, "PRAGMA journal_mode")
          assert mode == "wal"
        end)
    end
  end

  describe "execute/3 with params" do
    test "parameterized insert", %{db_path: db_path} do
      {:ok, _} =
        Sqlite.with_connection(db_path, :readwrite, fn conn ->
          :ok = Sqlite.execute(conn, "CREATE TABLE t (name TEXT, val INTEGER)")
          :ok = Sqlite.execute(conn, "INSERT INTO t VALUES (?, ?)", ["hello", 42])

          {:ok, %{rows: rows}} = Sqlite.query(conn, "SELECT * FROM t")
          assert rows == [["hello", 42]]
        end)
    end
  end

  describe "query/3" do
    test "returns columns and rows", %{db_path: db_path} do
      {:ok, _} =
        Sqlite.with_connection(db_path, :readwrite, fn conn ->
          :ok = Sqlite.execute(conn, "CREATE TABLE t (a TEXT, b INTEGER)")
          :ok = Sqlite.execute(conn, "INSERT INTO t VALUES (?, ?)", ["x", 1])
          :ok = Sqlite.execute(conn, "INSERT INTO t VALUES (?, ?)", ["y", 2])

          assert {:ok, %{columns: ["a", "b"], rows: [["x", 1], ["y", 2]]}} =
                   Sqlite.query(conn, "SELECT * FROM t ORDER BY a")
        end)
    end

    test "truncates at max rows", %{db_path: db_path} do
      {:ok, _} =
        Sqlite.with_connection(db_path, :readwrite, fn conn ->
          :ok = Sqlite.execute(conn, "CREATE TABLE t (id INTEGER)")

          # Insert more than default max rows
          for i <- 1..(Sqlite.default_max_rows() + 10) do
            :ok = Sqlite.execute(conn, "INSERT INTO t VALUES (?)", [i])
          end

          {:ok, result} = Sqlite.query(conn, "SELECT * FROM t")
          assert length(result.rows) == Sqlite.default_max_rows()
          assert result.truncated == true
        end)
    end
  end

  describe "transaction/2" do
    test "commits on success", %{db_path: db_path} do
      {:ok, _} =
        Sqlite.with_connection(db_path, :readwrite, fn conn ->
          :ok = Sqlite.execute(conn, "CREATE TABLE t (id INTEGER)")

          {:ok, :done} =
            Sqlite.transaction(conn, fn c ->
              :ok = Sqlite.execute(c, "INSERT INTO t VALUES (1)")
              :ok = Sqlite.execute(c, "INSERT INTO t VALUES (2)")
              :done
            end)

          {:ok, %{rows: rows}} = Sqlite.query(conn, "SELECT COUNT(*) FROM t")
          assert rows == [[2]]
        end)
    end

    test "rolls back on error", %{db_path: db_path} do
      {:ok, _} =
        Sqlite.with_connection(db_path, :readwrite, fn conn ->
          :ok = Sqlite.execute(conn, "CREATE TABLE t (id INTEGER)")

          {:error, _} =
            Sqlite.transaction(conn, fn c ->
              :ok = Sqlite.execute(c, "INSERT INTO t VALUES (1)")
              raise "oops"
            end)

          {:ok, %{rows: rows}} = Sqlite.query(conn, "SELECT COUNT(*) FROM t")
          assert rows == [[0]]
        end)
    end
  end

  describe "db_path/1" do
    test "appends data.db to version dir" do
      assert Sqlite.db_path("/some/path/1.0.0") == "/some/path/1.0.0/data.db"
    end
  end

  describe "check_db_size/1" do
    test "returns :ok for non-existent file" do
      assert :ok = Sqlite.check_db_size("/nonexistent/path/data.db")
    end

    test "returns :ok for small file", %{db_path: db_path} do
      File.write!(db_path, "small")
      assert :ok = Sqlite.check_db_size(db_path)
    end

    test "returns error for oversized file", %{dir: dir} do
      big_path = Path.join(dir, "big.db")
      # Create a file larger than the limit (use sparse/seek approach)
      {:ok, file} = File.open(big_path, [:write])
      # Write just past the limit
      {:ok, _} = :file.position(file, Sqlite.max_db_size_bytes() + 1)
      IO.binwrite(file, <<0>>)
      File.close(file)

      assert {:error, msg} = Sqlite.check_db_size(big_path)
      assert msg =~ "exceeds limit"
    end
  end
end
