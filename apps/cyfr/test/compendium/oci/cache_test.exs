defmodule Compendium.OCI.CacheTest do
  use ExUnit.Case

  alias Compendium.OCI.Cache

  setup do
    # Use a temporary cache directory for each test
    test_dir = Path.join(System.tmp_dir!(), "cyfr_oci_cache_test_#{:rand.uniform(1_000_000)}")
    Application.put_env(:cyfr, :oci_cache_dir, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
      Application.delete_env(:cyfr, :oci_cache_dir)
    end)

    %{cache_dir: test_dir}
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

  describe "all_blobs_cached?/1" do
    test "returns true when all blobs are cached" do
      c1 = "content 1"
      c2 = "content 2"
      d1 = Compendium.OCI.Blob.compute_digest(c1)
      d2 = Compendium.OCI.Blob.compute_digest(c2)
      Cache.put_blob(d1, c1)
      Cache.put_blob(d2, c2)

      assert Cache.all_blobs_cached?([d1, d2])
    end

    test "returns false when some blobs are missing" do
      c1 = "content 1"
      d1 = Compendium.OCI.Blob.compute_digest(c1)
      Cache.put_blob(d1, c1)

      refute Cache.all_blobs_cached?([d1, "sha256:nonexistent"])
    end

    test "returns true for empty list" do
      assert Cache.all_blobs_cached?([])
    end
  end

  describe "index operations" do
    test "tag digest is tracked in index" do
      registry = "ghcr.io"
      repo = "cyfr/reagents/test"
      tag = "1.0.0"
      digest = "sha256:manifest_digest"

      Cache.put_manifest(registry, repo, tag, "{}", digest)

      assert {:ok, ^digest} = Cache.get_tag_digest(registry, repo, tag)
    end

    test "get_tag_digest returns :miss for unknown" do
      assert :miss = Cache.get_tag_digest("unknown.io", "test/repo", "latest")
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
