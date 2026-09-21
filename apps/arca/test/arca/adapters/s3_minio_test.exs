# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.S3MinioTest do
  @moduledoc """
  Real-service integration coverage for `Arca.Adapters.S3`, against MinIO.

  The stub suite (`s3_test.exs`) verifies request *shape*; nothing there can
  catch a signature the server rejects. This suite exercises the parts only
  a real S3 implementation validates: SigV4 over pre-percent-encoded URLs
  (unicode/space/plus keys), the Content-MD5-signed DeleteObjects batch,
  and full round-trips through every callback.

  Excluded from ordinary runs; the `s3-minio` CI job runs it with
  `mix test --only s3_integration` against a MinIO
  container. `Arca.Test.S3Env` names the store, with defaults for that
  container, so the same suite runs against another S3-compatible store
  by environment alone. Locally:

      docker run -d -p 9000:9000 -e MINIO_ROOT_USER=cyfrtest \\
        -e MINIO_ROOT_PASSWORD=cyfrtest123 minio/minio server /data
      mix test --only s3_integration
  """

  use ExUnit.Case, async: false

  @moduletag :s3_integration

  alias Arca.Adapters.S3

  setup_all do
    previous = Arca.Test.S3Env.configure!()
    :ok = Arca.Test.S3Env.create_bucket!()

    on_exit(fn -> Arca.Test.S3Env.restore(previous) end)
    :ok
  end

  setup do
    {:ok, actor: Arca.Test.Actor.local()}
  end

  test "round-trips keys the signer must percent-encode", %{actor: actor} do
    # These names break a signer that double-encodes (or forgets to encode)
    # the canonical URI — exactly what the stub suite cannot verify.
    for name <- ["plain.txt", "with space.txt", "plus+plus.txt", "文件名.json", "📁data.bin"] do
      path = ["data", "sig", name]
      content = "content of #{name}"

      assert :ok = S3.put(actor, path, content)
      assert {:ok, ^content} = S3.get(actor, path)
      assert S3.exists?(actor, path)
      assert :ok = S3.delete(actor, path)
      assert {:error, :not_found} = S3.get(actor, path)
    end
  end

  test "listing callbacks agree with what was written", %{actor: actor} do
    :ok = S3.put(actor, ["data", "walk", "a.txt"], "a")
    :ok = S3.put(actor, ["data", "walk", "b.txt"], "bb")
    :ok = S3.put(actor, ["data", "walk", "sub", "c.txt"], "ccc")

    assert {:ok, entries} = S3.list_typed(actor, ["data", "walk"])
    assert Enum.sort(entries) == [{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}]

    assert {:error, :enotdir} =
             S3.list_typed(actor, ["data", "walk", "a.txt"])

    assert {:ok, []} = S3.list_typed(actor, ["data", "walk", "nothing"])

    assert {:ok, leaves} = S3.list_recursive(actor, ["data", "walk"])

    assert Enum.sort(leaves) == [
             ["data", "walk", "a.txt"],
             ["data", "walk", "b.txt"],
             ["data", "walk", "sub", "c.txt"]
           ]

    assert {:ok, %{files: 3, bytes: 6}} = S3.usage(actor, ["data", "walk"])

    assert {:ok, pairs} = Arca.Storage.read_subtree_via(S3, actor, ["data", "walk"])

    assert Enum.sort(pairs) == [
             {["a.txt"], "a"},
             {["b.txt"], "bb"},
             {["sub", "c.txt"], "ccc"}
           ]

    assert :ok = S3.delete_tree(actor, ["data", "walk"])
    assert {:ok, []} = S3.list_recursive(actor, ["data", "walk"])
  end

  test "append extends in place and delete_tree's batch really deletes", %{actor: actor} do
    path = ["data", "log", "events.jsonl"]
    assert :ok = S3.append(actor, path, "one\n")
    assert :ok = S3.append(actor, path, "two\n")
    assert {:ok, "one\ntwo\n"} = S3.get(actor, path)

    # The DeleteObjects batch is Content-MD5-signed — a real service
    # rejects a bad digest, which no stub can prove.
    assert :ok = S3.delete_tree(actor, ["data", "log"])
    refute S3.exists?(actor, path)
  end

  test "conditional headers ride inside the signature, on keys the signer must encode",
       %{actor: actor} do
    # If-None-Match and If-Match are signed headers: a signer that leaves
    # them out of SignedHeaders, or mis-encodes the key beside them, is a
    # 403 only a real service answers. The parity suite
    # (`Arca.AppendParityTest`) runs the races against this service.
    :ok = S3.delete_tree(actor, ["data", "cond"])

    for name <- ["plain", "with space", "plus+plus", "文件名", "📁unit"] do
      key = ["data", "cond", name]

      assert {:ok, first} = S3.put_if_none_match(actor, key, "v1")
      assert {:error, :exists} = S3.put_if_none_match(actor, key, "other")

      assert {:ok, second} = S3.put_if_match(actor, key, "v2", first)
      assert second != first

      assert {:error, :precondition_failed} =
               S3.put_if_match(actor, key, "v3", first)

      assert {:ok, "v2"} = S3.get(actor, key)

      # The precondition is the service's own ETag for the bytes.
      assert second == ~s("#{Base.encode16(:crypto.hash(:md5, "v2"), case: :lower)}")

      assert :ok = S3.delete(actor, key)
      assert {:error, :missing} = S3.put_if_match(actor, key, "v3", second)
      refute S3.exists?(actor, key)
    end
  end

  test "list_prefix/2 answers what was written: a tree, one object, nothing", %{actor: actor} do
    # The bucket outlives a run; start from nothing whatever the last one left.
    :ok = S3.delete_tree(actor, ["data", "reg"])
    :ok = S3.delete_tree(actor, ["data", "reg-other"])
    {:ok, _} = S3.put_if_none_match(actor, ["data", "reg", "u1"], "1")

    {:ok, _} =
      S3.put_if_none_match(actor, ["data", "reg", "deep", "u 2"], "2")

    assert {:ok, keys} = S3.list_prefix(actor, ["data", "reg"])
    assert Enum.sort(keys) == [["data", "reg", "deep", "u 2"], ["data", "reg", "u1"]]

    assert {:ok, [["data", "reg", "u1"]]} =
             S3.list_prefix(actor, ["data", "reg", "u1"])

    assert {:ok, []} = S3.list_prefix(actor, ["data", "reg", "absent"])

    # A sibling that only shares the spelling is not under the prefix.
    {:ok, _} = S3.put_if_none_match(actor, ["data", "reg-other"], "x")
    assert {:ok, keys} = S3.list_prefix(actor, ["data", "reg"])
    assert length(keys) == 2

    assert :ok = S3.delete_tree(actor, ["data", "reg"])
    assert :ok = S3.delete(actor, ["data", "reg-other"])
  end

  test "a configured key prefix scopes every object", %{actor: actor} do
    prev = Application.fetch_env!(:arca, :s3)
    Application.put_env(:arca, :s3, Keyword.put(prev, :prefix, "tenants/it"))
    on_exit(fn -> Application.put_env(:arca, :s3, prev) end)

    assert :ok = S3.put(actor, ["data", "prefixed.txt"], "p")
    assert {:ok, "p"} = S3.get(actor, ["data", "prefixed.txt"])

    # Without the prefix the object is elsewhere in the bucket.
    Application.put_env(:arca, :s3, prev)
    assert {:error, :not_found} = S3.get(actor, ["data", "prefixed.txt"])
  end
end
