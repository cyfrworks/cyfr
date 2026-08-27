# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.CacheTest do
  use ExUnit.Case

  alias Compendium.OCI.Cache

  describe "blob operations" do
    test "put and get blob" do
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
      content = "test content"
      digest = Compendium.OCI.Blob.compute_digest(content)
      Cache.put_blob(digest, content)

      # `put_blob/2` writes whatever bytes it is given at the path the digest
      # names — it does not verify them — so storing the wrong content under a
      # digest IS the corruption, without reaching around Arca for a real path.
      Cache.put_blob(digest, "corrupted data")

      assert :miss = Cache.get_blob(digest)
      # The corrupt entry is removed on detection, not left to be re-read.
      refute Arca.exists?(Sanctum.system_context(), blob_segments(digest))
    end

    defp blob_segments("sha256:" <> hex), do: ["cache", "oci", "blobs", "sha256", hex]
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

  describe "layout" do
    test "the cache lives under a global root — never a tenant's tree" do
      content = "layout-witness"
      digest = Compendium.OCI.Blob.compute_digest(content)
      Cache.put_blob(digest, content)

      ctx = Sanctum.system_context()
      {:ok, leaves} = Arca.list_recursive(ctx, ["cache"])

      assert leaves != []

      for leaf <- leaves do
        assert hd(leaf) in Arca.Storage.global_prefixes()
      end
    end
  end
end
