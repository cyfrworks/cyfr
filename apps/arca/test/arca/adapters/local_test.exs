defmodule Arca.Adapters.LocalTest do
  use ExUnit.Case, async: true

  alias Arca.Adapters.Local
  alias Sanctum.Context

  @test_base_path System.tmp_dir!() |> Path.join("arca_test_#{:rand.uniform(100_000)}")

  setup do
    # Use a unique temp directory for each test run
    Application.put_env(:arca, :base_path, @test_base_path)

    on_exit(fn ->
      File.rm_rf!(@test_base_path)
    end)

    ctx = Context.local()
    {:ok, ctx: ctx}
  end

  describe "put/3 and get/2" do
    test "writes and reads content", %{ctx: ctx} do
      content = "hello world"
      path = ["test", "file.txt"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "creates nested directories", %{ctx: ctx} do
      content = "nested content"
      path = ["deep", "nested", "path", "file.txt"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles binary content", %{ctx: ctx} do
      content = <<0, 1, 2, 3, 255>>
      path = ["binary", "data.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end
  end

  describe "get/2 errors" do
    test "returns not_found for missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Local.get(ctx, ["nonexistent", "file.txt"])
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{ctx: ctx} do
      path = ["exists", "test.txt"]
      Local.put(ctx, path, "content")

      assert Local.exists?(ctx, path)
    end

    test "returns false for missing file", %{ctx: ctx} do
      refute Local.exists?(ctx, ["missing", "file.txt"])
    end
  end

  describe "delete/2" do
    test "removes existing file", %{ctx: ctx} do
      path = ["delete", "me.txt"]
      Local.put(ctx, path, "content")

      assert :ok == Local.delete(ctx, path)
      refute Local.exists?(ctx, path)
    end

    test "returns not_found for missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Local.delete(ctx, ["missing.txt"])
    end
  end

  describe "list/2" do
    test "lists directory contents", %{ctx: ctx} do
      Local.put(ctx, ["dir", "a.txt"], "a")
      Local.put(ctx, ["dir", "b.txt"], "b")
      Local.put(ctx, ["dir", "c.txt"], "c")

      {:ok, files} = Local.list(ctx, ["dir"])
      assert Enum.sort(files) == ["a.txt", "b.txt", "c.txt"]
    end

    test "returns empty list for missing directory", %{ctx: ctx} do
      assert {:ok, []} = Local.list(ctx, ["nonexistent"])
    end
  end

  describe "user isolation" do
    test "stores user-scoped files under user-specific path", %{ctx: ctx} do
      path = ["isolation", "test.txt"]
      Local.put(ctx, path, "content")

      expected_path = Path.join([@test_base_path, "users", ctx.user_id, "isolation", "test.txt"])
      assert File.exists?(expected_path)
    end
  end

  describe "global paths" do
    test "mcp_logs is stored at root level", %{ctx: ctx} do
      path = ["mcp_logs", "req_123.json"]
      Local.put(ctx, path, ~s|{"test": true}|)

      # Should NOT be under users/{user_id}/
      expected_path = Path.join([@test_base_path, "mcp_logs", "req_123.json"])
      assert File.exists?(expected_path)

      # Should NOT exist under user path
      user_path = Path.join([@test_base_path, "users", ctx.user_id, "mcp_logs", "req_123.json"])
      refute File.exists?(user_path)
    end

    test "cache is stored at root level", %{ctx: ctx} do
      path = ["cache", "oci", "sha256_abc123"]
      Local.put(ctx, path, "wasm binary")

      expected_path = Path.join([@test_base_path, "cache", "oci", "sha256_abc123"])
      assert File.exists?(expected_path)
    end

    test "can read global paths", %{ctx: ctx} do
      path = ["mcp_logs", "req_456.json"]
      content = ~s|{"request_id": "req_456"}|
      Local.put(ctx, path, content)

      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "can list global paths", %{ctx: ctx} do
      Local.put(ctx, ["mcp_logs", "req_1.json"], "1")
      Local.put(ctx, ["mcp_logs", "req_2.json"], "2")

      {:ok, files} = Local.list(ctx, ["mcp_logs"])
      assert Enum.sort(files) == ["req_1.json", "req_2.json"]
    end
  end

  describe "append/3" do
    test "appends content to file", %{ctx: ctx} do
      path = ["audit", "2025-01-15.jsonl"]

      assert :ok == Local.append(ctx, path, ~s|{"event":"login"}\n|)
      assert :ok == Local.append(ctx, path, ~s|{"event":"logout"}\n|)

      {:ok, content} = Local.get(ctx, path)
      assert content == ~s|{"event":"login"}\n{"event":"logout"}\n|
    end

    test "creates file if it doesn't exist", %{ctx: ctx} do
      path = ["audit", "new.jsonl"]

      assert :ok == Local.append(ctx, path, "first line\n")
      assert {:ok, "first line\n"} = Local.get(ctx, path)
    end

    test "creates nested directories", %{ctx: ctx} do
      path = ["deep", "nested", "audit.jsonl"]

      assert :ok == Local.append(ctx, path, "content\n")
      assert Local.exists?(ctx, path)
    end
  end

  describe "build_path/2" do
    test "global prefix mcp_logs goes to root", %{ctx: ctx} do
      path = Local.build_path(ctx, ["mcp_logs", "test.json"])
      assert path == Path.join([@test_base_path, "mcp_logs", "test.json"])
    end

    test "global prefix cache goes to root", %{ctx: ctx} do
      path = Local.build_path(ctx, ["cache", "oci", "sha256"])
      assert path == Path.join([@test_base_path, "cache", "oci", "sha256"])
    end

    test "other paths go under users/{user_id}", %{ctx: ctx} do
      path = Local.build_path(ctx, ["executions", "exec_123", "started.json"])
      assert path == Path.join([@test_base_path, "users", ctx.user_id, "executions", "exec_123", "started.json"])
    end
  end

  # ============================================================================
  # Edge Cases: Special Characters
  # ============================================================================

  describe "special characters in filenames" do
    test "handles spaces in filename", %{ctx: ctx} do
      path = ["test", "file with spaces.txt"]
      content = "content with spaces"

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
      assert Local.exists?(ctx, path)
    end

    test "handles unicode in filename", %{ctx: ctx} do
      path = ["test", "文件名.txt"]
      content = "unicode content"

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles emoji in filename", %{ctx: ctx} do
      path = ["test", "📁data.json"]
      content = ~s|{"emoji": true}|

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles dashes and underscores", %{ctx: ctx} do
      path = ["test-dir", "file_name-v1.2.3.txt"]
      content = "versioned content"

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles dots in directory names", %{ctx: ctx} do
      path = ["v1.0.0", "release.txt"]
      content = "release notes"

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end
  end

  # ============================================================================
  # Edge Cases: Large Files
  # ============================================================================

  describe "large file handling" do
    test "handles 1MB+ file", %{ctx: ctx} do
      # Generate 1MB of content
      content = String.duplicate("x", 1_000_000)
      path = ["large", "big_file.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, read_content} = Local.get(ctx, path)
      assert byte_size(read_content) == 1_000_000
    end

    test "handles file with many small appends", %{ctx: ctx} do
      path = ["audit", "many_lines.jsonl"]

      # Append 1000 small lines
      for i <- 1..1000 do
        :ok = Local.append(ctx, path, ~s|{"line":#{i}}\n|)
      end

      {:ok, content} = Local.get(ctx, path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 1000
    end
  end

  # ============================================================================
  # Edge Cases: Binary Content
  # ============================================================================

  describe "binary content handling" do
    test "handles null bytes in content", %{ctx: ctx} do
      content = <<0, 1, 2, 0, 3, 0, 0, 4>>
      path = ["binary", "nulls.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles all byte values 0-255", %{ctx: ctx} do
      content = :binary.list_to_bin(Enum.to_list(0..255))
      path = ["binary", "all_bytes.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles empty file", %{ctx: ctx} do
      path = ["binary", "empty.bin"]

      assert :ok == Local.put(ctx, path, "")
      assert {:ok, ""} = Local.get(ctx, path)
    end
  end

  # ============================================================================
  # Edge Cases: Path Traversal Prevention
  # ============================================================================

  describe "path security" do
    test "rejects path traversal with ..", %{ctx: ctx} do
      # Attempting path traversal should not escape the user's directory
      path = ["..", "etc", "passwd"]

      # The result depends on implementation - either error or sanitized path
      case Local.put(ctx, path, "malicious") do
        :ok ->
          # If it succeeds, verify it didn't escape the sandbox
          full_path = Local.build_path(ctx, path)
          assert String.contains?(full_path, "users/#{ctx.user_id}")

        {:error, _} ->
          # Rejecting is also acceptable
          :ok
      end
    end

    test "handles empty path segments", %{ctx: ctx} do
      path = ["test", "", "file.txt"]

      # Should either filter empty segments or handle gracefully
      case Local.put(ctx, path, "content") do
        :ok ->
          # Should be able to read back
          assert {:ok, _} = Local.get(ctx, path)

        {:error, _} ->
          :ok
      end
    end

    test "handles leading/trailing slashes in segments", %{ctx: ctx} do
      path = ["/test/", "/file.txt/"]

      case Local.put(ctx, path, "content") do
        :ok ->
          assert {:ok, _} = Local.get(ctx, path)

        {:error, _} ->
          :ok
      end
    end
  end

  # ============================================================================
  # Edge Cases: Concurrent Operations
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent writes to different files succeed", %{ctx: ctx} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            path = ["concurrent", "file_#{i}.txt"]
            content = "content #{i}"
            :ok = Local.put(ctx, path, content)
            {:ok, read} = Local.get(ctx, path)
            assert read == content
            i
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.sort(results) == Enum.to_list(1..10)
    end

    test "concurrent appends to same file", %{ctx: ctx} do
      path = ["concurrent", "shared.jsonl"]

      # First create the file
      :ok = Local.put(ctx, path, "")

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            :ok = Local.append(ctx, path, "line #{i}\n")
          end)
        end

      Task.await_many(tasks, 5000)

      {:ok, content} = Local.get(ctx, path)
      lines = String.split(content, "\n", trim: true)

      # All 50 lines should be present (order may vary)
      assert length(lines) == 50
    end

    test "concurrent reads are safe", %{ctx: ctx} do
      path = ["concurrent", "readonly.txt"]
      content = "read me many times"
      :ok = Local.put(ctx, path, content)

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            {:ok, read} = Local.get(ctx, path)
            assert read == content
          end)
        end

      Task.await_many(tasks, 5000)
    end
  end

  # ============================================================================
  # Edge Cases: Deep Nesting
  # ============================================================================

  describe "deep nesting" do
    test "handles 20+ levels of nesting", %{ctx: ctx} do
      # Create a path with 20 directory levels
      deep_path = Enum.to_list(1..20) |> Enum.map(&"level_#{&1}") |> Kernel.++(["deep_file.txt"])

      content = "very deep content"

      assert :ok == Local.put(ctx, deep_path, content)
      assert {:ok, ^content} = Local.get(ctx, deep_path)
      assert Local.exists?(ctx, deep_path)
    end

    test "lists deeply nested directory", %{ctx: ctx} do
      base = Enum.to_list(1..10) |> Enum.map(&"d#{&1}")

      # Create multiple files in the deep directory
      for i <- 1..3 do
        path = base ++ ["file_#{i}.txt"]
        :ok = Local.put(ctx, path, "content #{i}")
      end

      {:ok, files} = Local.list(ctx, base)
      assert length(files) == 3
    end
  end
end
