# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.LocalTest do
  use ExUnit.Case, async: false

  alias Arca.Adapters.Local

  @test_base_path System.tmp_dir!() |> Path.join("arca_test_#{:rand.uniform(100_000)}")

  setup do
    # Use a unique temp directory for each test run
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, @test_base_path)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(@test_base_path)
    end)

    ctx = Sanctum.TestContext.local()
    {:ok, ctx: ctx}
  end

  describe "put/3 and get/2" do
    test "writes and reads content", %{ctx: ctx} do
      content = "hello world"
      path = ["guest", "file.txt"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "creates nested directories", %{ctx: ctx} do
      content = "nested content"
      path = ["guest", "nested", "path", "file.txt"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles binary content", %{ctx: ctx} do
      content = <<0, 1, 2, 3, 255>>
      path = ["guest", "data.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end
  end

  describe "get/2 errors" do
    test "returns not_found for missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Local.get(ctx, ["guest", "nonexistent", "file.txt"])
    end
  end

  describe "atomic-write hygiene" do
    test "in-flight temp names are invisible to listings, walks and usage", %{ctx: ctx} do
      :ok = Local.put(ctx, ["guest", "a.txt"], "a")

      # A crashed put's orphan, next to its target.
      orphan = Local.build_path(ctx, ["guest", "a.txt"]) <> ".tmp.12345"
      File.write!(orphan, "partial")

      assert {:ok, [{"a.txt", :file}]} = Local.list_typed(ctx, ["guest"])
      assert {:ok, [["guest", "a.txt"]]} = Local.list_recursive(ctx, ["guest"])
      assert {:ok, %{files: 1}} = Local.usage(ctx, ["guest"])
    end

    test "sweep_stale_tmp/1 removes only stale temp files", %{ctx: ctx} do
      :ok = Local.put(ctx, ["guest", "a.txt"], "a")
      orphan = Local.build_path(ctx, ["guest", "a.txt"]) <> ".tmp.999"
      File.write!(orphan, "partial")

      # Too fresh to sweep.
      assert {:ok, 0} = Local.sweep_stale_tmp(3600)
      assert File.exists?(orphan)

      # A negative age makes everything stale.
      assert {:ok, 1} = Local.sweep_stale_tmp(-1)
      refute File.exists?(orphan)
      assert {:ok, "a"} = Local.get(ctx, ["guest", "a.txt"])
    end
  end

  describe "symlinks" do
    test "walks do not follow a symlink out of the tree", %{ctx: ctx} do
      :ok = Local.put(ctx, ["guest", "a.txt"], "a")

      outside = Path.join(System.tmp_dir!(), "arca_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret")
      on_exit(fn -> File.rm_rf!(outside) end)

      tree_dir = Local.build_path(ctx, ["guest", "a.txt"]) |> Path.dirname()
      File.ln_s!(outside, Path.join(tree_dir, "link"))

      assert {:ok, [["guest", "a.txt"]]} = Local.list_recursive(ctx, ["guest"])
      assert {:ok, %{files: 1, bytes: 1}} = Local.usage(ctx, ["guest"])
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{ctx: ctx} do
      path = ["guest", "test.txt"]
      Local.put(ctx, path, "content")

      assert Local.exists?(ctx, path)
    end

    test "returns false for missing file", %{ctx: ctx} do
      refute Local.exists?(ctx, ["guest", "missing", "file.txt"])
    end
  end

  describe "delete/2" do
    test "removes existing file", %{ctx: ctx} do
      path = ["guest", "me.txt"]
      Local.put(ctx, path, "content")

      assert :ok == Local.delete(ctx, path)
      refute Local.exists?(ctx, path)
    end

    test "returns not_found for missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Local.delete(ctx, ["guest", "missing.txt"])
    end
  end

  describe "list/2" do
    test "lists directory contents", %{ctx: ctx} do
      Local.put(ctx, ["guest", "dir", "a.txt"], "a")
      Local.put(ctx, ["guest", "dir", "b.txt"], "b")
      Local.put(ctx, ["guest", "dir", "c.txt"], "c")

      {:ok, files} = Local.list(ctx, ["guest", "dir"])
      assert Enum.sort(files) == ["a.txt", "b.txt", "c.txt"]
    end

    test "returns empty list for missing directory", %{ctx: ctx} do
      assert {:ok, []} = Local.list(ctx, ["guest", "nonexistent"])
    end
  end

  describe "tenant-scoped paths" do
    test "stores files under {athanor_id} (namespace not in path)", %{ctx: ctx} do
      path = ["guest", "isolation", "test.txt"]
      Local.put(ctx, path, "content")

      # namespace is identity-only; the path is athanors/{athanor_id}/...
      expected_path =
        Path.join([@test_base_path, "athanors", ctx.athanor_id, "guest", "isolation", "test.txt"])

      assert File.exists?(expected_path)
    end
  end

  describe "global paths" do
    test "cache is stored at root level", %{ctx: ctx} do
      path = ["cache", "oci", "sha256_abc123"]
      Local.put(ctx, path, "wasm binary")

      expected_path = Path.join([@test_base_path, "cache", "oci", "sha256_abc123"])
      assert File.exists?(expected_path)
    end

    test "can read global paths", %{ctx: ctx} do
      path = ["cache", "oci", "sha256_test"]
      content = "cached content"
      Local.put(ctx, path, content)

      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "can list global paths", %{ctx: ctx} do
      Local.put(ctx, ["cache", "test_1.bin"], "1")
      Local.put(ctx, ["cache", "test_2.bin"], "2")

      {:ok, files} = Local.list(ctx, ["cache"])
      assert "test_1.bin" in files
      assert "test_2.bin" in files
    end
  end

  describe "append/3" do
    test "appends content to file", %{ctx: ctx} do
      path = ["guest", "2025-01-15.jsonl"]

      assert :ok == Local.append(ctx, path, ~s|{"event":"login"}\n|)
      assert :ok == Local.append(ctx, path, ~s|{"event":"logout"}\n|)

      {:ok, content} = Local.get(ctx, path)
      assert content == ~s|{"event":"login"}\n{"event":"logout"}\n|
    end

    test "creates file if it doesn't exist", %{ctx: ctx} do
      path = ["guest", "new.jsonl"]

      assert :ok == Local.append(ctx, path, "first line\n")
      assert {:ok, "first line\n"} = Local.get(ctx, path)
    end

    test "creates nested directories", %{ctx: ctx} do
      path = ["guest", "nested", "audit.jsonl"]

      assert :ok == Local.append(ctx, path, "content\n")
      assert Local.exists?(ctx, path)
    end
  end

  describe "build_path/2" do
    test "global prefix cache goes to root", %{ctx: ctx} do
      path = Local.build_path(ctx, ["cache", "oci", "sha256"])
      assert path == Path.join([@test_base_path, "cache", "oci", "sha256"])
    end

    test "tenant paths go verbatim under athanors/{athanor_id} (no namespace segment)", %{
      ctx: ctx
    } do
      path = Local.build_path(ctx, ["config", "sub", "retention.json"])

      assert path ==
               Path.join([
                 @test_base_path,
                 "athanors",
                 ctx.athanor_id,
                 "config",
                 "sub",
                 "retention.json"
               ])
    end

    test "component paths go under the context's athanors/{athanor_id}/components", %{ctx: ctx} do
      path = Local.build_path(ctx, ["components", "catalysts", "local", "t", "1.0.0"])

      assert path ==
               Path.join([
                 @test_base_path,
                 "athanors",
                 ctx.athanor_id,
                 "components",
                 "catalysts",
                 "local",
                 "t",
                 "1.0.0"
               ])
    end

    test "the seed bundle resolves under :seed_path, never the storage root", %{ctx: ctx} do
      path = Local.build_path(ctx, ["seed", "components", "catalysts", "local"])

      bundle =
        Application.fetch_env!(:cyfr, :seed_path) |> Path.expand() |> Path.join("components")

      assert path == Path.join([bundle, "catalysts", "local"])
      refute String.starts_with?(path, @test_base_path)
    end

    test "the bare components root is the athanor's own components subtree", %{ctx: ctx} do
      assert Local.build_path(ctx, ["components"]) ==
               Path.join([@test_base_path, "athanors", ctx.athanor_id, "components"])
    end
  end

  describe "usage/2" do
    test "the empty-path walk counts the whole athanor, components included", %{ctx: ctx} do
      # The storage cap's one walk: a cap that bounds one subtree is not a
      # cap on the athanor.
      :ok = Local.put(ctx, ["guest", "a.txt"], "12345")

      :ok =
        Local.put(
          ctx,
          ["components", "reagents", "local", "x", "1.0.0", "reagent.wasm"],
          "123"
        )

      assert {:ok, %{files: 2, bytes: 8}} = Local.usage(ctx, [])
      assert {:ok, %{files: 1, bytes: 3}} = Local.usage(ctx, ["components"])
    end

    test "a missing prefix is empty usage", %{ctx: ctx} do
      assert {:ok, %{files: 0, bytes: 0}} = Local.usage(ctx, ["guest", "never-written"])
    end
  end

  # ============================================================================
  # Edge Cases: Special Characters
  # ============================================================================

  describe "special characters in filenames" do
    test "handles spaces in filename", %{ctx: ctx} do
      path = ["guest", "file with spaces.txt"]
      content = "content with spaces"

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
      assert Local.exists?(ctx, path)
    end

    test "handles unicode in filename", %{ctx: ctx} do
      path = ["guest", "文件名.txt"]
      content = "unicode content"

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles emoji in filename", %{ctx: ctx} do
      path = ["guest", "📁data.json"]
      content = ~s|{"emoji": true}|

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles dashes and underscores", %{ctx: ctx} do
      path = ["guest", "test-dir", "file_name-v1.2.3.txt"]
      content = "versioned content"

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles dots in directory names", %{ctx: ctx} do
      path = ["guest", "v1.0.0", "release.txt"]
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
      path = ["guest", "big_file.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, read_content} = Local.get(ctx, path)
      assert byte_size(read_content) == 1_000_000
    end

    test "handles file with many small appends", %{ctx: ctx} do
      path = ["guest", "many_lines.jsonl"]

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
      path = ["guest", "nulls.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles all byte values 0-255", %{ctx: ctx} do
      content = :binary.list_to_bin(Enum.to_list(0..255))
      path = ["guest", "all_bytes.bin"]

      assert :ok == Local.put(ctx, path, content)
      assert {:ok, ^content} = Local.get(ctx, path)
    end

    test "handles empty file", %{ctx: ctx} do
      path = ["guest", "empty.bin"]

      assert :ok == Local.put(ctx, path, "")
      assert {:ok, ""} = Local.get(ctx, path)
    end
  end

  # ============================================================================
  # Edge Cases: Path Traversal Prevention
  # ============================================================================

  describe "path security" do
    test "rejects path traversal with ..", %{ctx: ctx} do
      # Path traversal segments are rejected with ArgumentError
      path = ["..", "etc", "passwd"]

      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Local.put(ctx, path, "malicious")
      end
    end

    test "rejects empty path segments at the adapter", %{ctx: ctx} do
      # The Arca facade drops split artifacts; a bare "" reaching an
      # adapter directly is refused rather than silently collapsed (the
      # two adapters used to disagree about which object it named).
      assert_raise ArgumentError, ~r/empty segments/, fn ->
        Local.put(ctx, ["guest", "", "file.txt"], "content")
      end
    end

    test "rejects segments with a leading slash (absolute-segment denylist)", %{ctx: ctx} do
      # Cyfr.PathSafety treats a leading "/" in any segment as an absolute
      # path fragment and fails closed rather than silently normalizing it.
      assert_raise ArgumentError, ~r/absolute segments are not allowed/, fn ->
        Local.put(ctx, ["/test/", "/file.txt/"], "content")
      end

      # Trailing slashes without a leading one remain acceptable input.
      case Local.put(ctx, ["guest", "test/", "file.txt/"], "content") do
        :ok -> assert {:ok, _} = Local.get(ctx, ["guest", "test/", "file.txt/"])
        {:error, _} -> :ok
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
            path = ["guest", "concurrent", "file_#{i}.txt"]
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
      path = ["guest", "concurrent", "shared.jsonl"]

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
      path = ["guest", "concurrent", "readonly.txt"]
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
      deep_path = ["guest" | Enum.map(1..20, &"level_#{&1}")] ++ ["deep_file.txt"]

      content = "very deep content"

      assert :ok == Local.put(ctx, deep_path, content)
      assert {:ok, ^content} = Local.get(ctx, deep_path)
      assert Local.exists?(ctx, deep_path)
    end

    test "lists deeply nested directory", %{ctx: ctx} do
      base = ["guest" | Enum.map(1..10, &"d#{&1}")]

      # Create multiple files in the deep directory
      for i <- 1..3 do
        path = base ++ ["file_#{i}.txt"]
        :ok = Local.put(ctx, path, "content #{i}")
      end

      {:ok, files} = Local.list(ctx, base)
      assert length(files) == 3
    end
  end

  describe "atomic put" do
    test "leaves no temp residue after a successful write", %{ctx: ctx} do
      :ok = Local.put(ctx, ["guest", "atomic", "target.txt"], "v1")
      :ok = Local.put(ctx, ["guest", "atomic", "target.txt"], "v2")

      assert {:ok, "v2"} = Local.get(ctx, ["guest", "atomic", "target.txt"])
      assert {:ok, ["target.txt"]} = Local.list(ctx, ["guest", "atomic"])
    end

    test "an overwrite failure cleans up its temp file", %{ctx: ctx} do
      # Renaming onto a non-empty directory fails on every platform, which
      # exercises the temp-cleanup path without needing to fake File.write.
      :ok = Local.put(ctx, ["guest", "atomic2", "occupied", "child.txt"], "x")

      assert {:error, _} = Local.put(ctx, ["guest", "atomic2", "occupied"], "clobber")

      # The directory survives untouched and the temp file (written next to
      # it, in atomic2/) is cleaned up.
      assert {:ok, ["child.txt"]} = Local.list(ctx, ["guest", "atomic2", "occupied"])
      assert {:ok, ["occupied"]} = Local.list(ctx, ["guest", "atomic2"])
    end
  end
end
