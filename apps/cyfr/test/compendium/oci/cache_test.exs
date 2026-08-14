# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.CacheTest do
  use ExUnit.Case

  alias Compendium.OCI.Cache

  setup do
    # Cache.cache_dir/0 derives its path from the Arca-local base path (a
    # per-run tmp dir in tests); there is no separate cache-dir setting.
    %{cache_dir: Cache.cache_dir()}
  end

  describe "blob operations" do
    test "put and get blob", %{cache_dir: _dir} do
      content = :crypto.strong_rand_bytes(256)
      digest = Compendium.OCI.Blob.compute_digest(content)

      assert :ok = Cache.put_blob(digest, content)
      assert {:ok, ^content} = Cache.get_blob(digest)
    end

    test "get_blob returns :miss for uncached digest" do
      assert :miss =
               Cache.get_blob(
                 "sha256:0000000000000000000000000000000000000000000000000000000000000000"
               )
    end

    test "get_blob returns :miss for invalid digest format" do
      assert :miss = Cache.get_blob("invalid")
    end

    test "detects corrupted cache entries" do
      # Store a blob, then corrupt the file
      content = "test content"
      digest = Compendium.OCI.Blob.compute_digest(content)
      Cache.put_blob(digest, content)

      # Corrupt the file
      "sha256:" <> hex = digest
      blob_path = Path.join([Cache.cache_dir(), "blobs", "sha256", hex])
      File.write!(blob_path, "corrupted data")

      # Should detect corruption and return :miss
      assert :miss = Cache.get_blob(digest)
      # Corrupt file should be removed
      refute File.exists?(blob_path)
    end
  end

  describe "manifest operations" do
    test "put and get manifest" do
      registry = "ghcr.io"
      repo = "cyfr/reagents/test"
      tag = "1.0.0"
      manifest = ~s({"schemaVersion":2})
      digest = "sha256:abc123"

      assert :ok = Cache.put_manifest(registry, repo, tag, manifest, digest)
      assert {:ok, ^manifest, ^digest} = Cache.get_manifest(registry, repo, tag)
    end

    test "get_manifest returns :miss for uncached" do
      assert :miss = Cache.get_manifest("unknown.io", "test/repo", "latest")
    end
  end

  describe "clear/0" do
    test "removes all cached data" do
      content = "test"
      digest = Compendium.OCI.Blob.compute_digest(content)
      Cache.put_blob(digest, content)
      Cache.put_manifest("reg.io", "test/repo", "v1", "{}", "sha256:m")

      assert {:ok, _} = Cache.get_blob(digest)

      Cache.clear()

      assert :miss = Cache.get_blob(digest)
      assert :miss = Cache.get_manifest("reg.io", "test/repo", "v1")
    end
  end
end
