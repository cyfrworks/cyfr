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
  `mix test --only s3_integration` against a MinIO container. Locally:

      docker run -d -p 9000:9000 -e MINIO_ROOT_USER=cyfrtest \\
        -e MINIO_ROOT_PASSWORD=cyfrtest123 minio/minio server /data
      cd apps/cyfr && mix test --only s3_integration
  """

  use ExUnit.Case, async: false

  @moduletag :s3_integration

  alias Arca.Adapters.S3

  @bucket "cyfr-test"
  # Non-secret CI fixtures, mirrored in .github/workflows/test.yml.
  @access "cyfrtest"
  @secret "cyfrtest123"
  @region "us-east-1"

  setup_all do
    endpoint = System.get_env("CYFR_TEST_MINIO_ENDPOINT") || "http://127.0.0.1:9000"
    prev = Application.get_env(:cyfr, :s3)

    Application.put_env(:cyfr, :s3,
      bucket: @bucket,
      region: @region,
      endpoint: endpoint,
      access_key_id: @access,
      secret_access_key: @secret,
      prefix: nil,
      path_style: true
    )

    create_bucket!(endpoint)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :s3, prev),
        else: Application.delete_env(:cyfr, :s3)
    end)

    :ok
  end

  setup do
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "round-trips keys the signer must percent-encode", %{ctx: ctx} do
    # These names break a signer that double-encodes (or forgets to encode)
    # the canonical URI — exactly what the stub suite cannot verify.
    for name <- ["plain.txt", "with space.txt", "plus+plus.txt", "文件名.json", "📁data.bin"] do
      path = ["data", "sig", name]
      content = "content of #{name}"

      assert :ok = S3.put(ctx, path, content)
      assert {:ok, ^content} = S3.get(ctx, path)
      assert S3.exists?(ctx, path)
      assert :ok = S3.delete(ctx, path)
      assert {:error, :not_found} = S3.get(ctx, path)
    end
  end

  test "listing callbacks agree with what was written", %{ctx: ctx} do
    :ok = S3.put(ctx, ["data", "walk", "a.txt"], "a")
    :ok = S3.put(ctx, ["data", "walk", "b.txt"], "bb")
    :ok = S3.put(ctx, ["data", "walk", "sub", "c.txt"], "ccc")

    assert {:ok, entries} = S3.list_typed(ctx, ["data", "walk"])
    assert Enum.sort(entries) == [{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}]

    assert {:error, :enotdir} = S3.list_typed(ctx, ["data", "walk", "a.txt"])
    assert {:ok, []} = S3.list_typed(ctx, ["data", "walk", "nothing"])

    assert {:ok, leaves} = S3.list_recursive(ctx, ["data", "walk"])

    assert Enum.sort(leaves) == [
             ["data", "walk", "a.txt"],
             ["data", "walk", "b.txt"],
             ["data", "walk", "sub", "c.txt"]
           ]

    assert {:ok, %{files: 3, bytes: 6}} = S3.usage(ctx, ["data", "walk"])

    assert {:ok, pairs} = Arca.Storage.read_subtree_via(S3, ctx, ["data", "walk"])

    assert Enum.sort(pairs) == [
             {["a.txt"], "a"},
             {["b.txt"], "bb"},
             {["sub", "c.txt"], "ccc"}
           ]

    assert :ok = S3.delete_tree(ctx, ["data", "walk"])
    assert {:ok, []} = S3.list_recursive(ctx, ["data", "walk"])
  end

  test "append extends in place and delete_tree's batch really deletes", %{ctx: ctx} do
    path = ["data", "log", "events.jsonl"]
    assert :ok = S3.append(ctx, path, "one\n")
    assert :ok = S3.append(ctx, path, "two\n")
    assert {:ok, "one\ntwo\n"} = S3.get(ctx, path)

    # The DeleteObjects batch is Content-MD5-signed — a real service
    # rejects a bad digest, which no stub can prove.
    assert :ok = S3.delete_tree(ctx, ["data", "log"])
    refute S3.exists?(ctx, path)
  end

  test "conditional headers ride inside the signature, on keys the signer must encode",
       %{ctx: ctx} do
    # If-None-Match and If-Match are signed headers: a signer that leaves
    # them out of SignedHeaders, or mis-encodes the key beside them, is a
    # 403 only a real service answers. The parity suite
    # (`Arca.AppendParityTest`) runs the races against this service.
    :ok = S3.delete_tree(ctx, ["data", "cond"])

    for name <- ["plain", "with space", "plus+plus", "文件名", "📁unit"] do
      key = ["data", "cond", name]

      assert {:ok, first} = S3.put_if_none_match(ctx, key, "v1")
      assert {:error, :exists} = S3.put_if_none_match(ctx, key, "other")

      assert {:ok, second} = S3.put_if_match(ctx, key, "v2", first)
      assert second != first
      assert {:error, :precondition_failed} = S3.put_if_match(ctx, key, "v3", first)
      assert {:ok, "v2"} = S3.get(ctx, key)

      # The precondition is the service's own ETag for the bytes.
      assert second == ~s("#{Base.encode16(:crypto.hash(:md5, "v2"), case: :lower)}")

      assert :ok = S3.delete(ctx, key)
      assert {:error, :missing} = S3.put_if_match(ctx, key, "v3", second)
      refute S3.exists?(ctx, key)
    end
  end

  test "list_prefix/2 answers what was written: a tree, one object, nothing", %{ctx: ctx} do
    # The bucket outlives a run; start from nothing whatever the last one left.
    :ok = S3.delete_tree(ctx, ["data", "reg"])
    :ok = S3.delete_tree(ctx, ["data", "reg-other"])
    {:ok, _} = S3.put_if_none_match(ctx, ["data", "reg", "u1"], "1")
    {:ok, _} = S3.put_if_none_match(ctx, ["data", "reg", "deep", "u 2"], "2")

    assert {:ok, keys} = S3.list_prefix(ctx, ["data", "reg"])
    assert Enum.sort(keys) == [["data", "reg", "deep", "u 2"], ["data", "reg", "u1"]]

    assert {:ok, [["data", "reg", "u1"]]} = S3.list_prefix(ctx, ["data", "reg", "u1"])
    assert {:ok, []} = S3.list_prefix(ctx, ["data", "reg", "absent"])

    # A sibling that only shares the spelling is not under the prefix.
    {:ok, _} = S3.put_if_none_match(ctx, ["data", "reg-other"], "x")
    assert {:ok, keys} = S3.list_prefix(ctx, ["data", "reg"])
    assert length(keys) == 2

    assert :ok = S3.delete_tree(ctx, ["data", "reg"])
    assert :ok = S3.delete(ctx, ["data", "reg-other"])
  end

  test "a configured key prefix scopes every object", %{ctx: ctx} do
    prev = Application.fetch_env!(:cyfr, :s3)
    Application.put_env(:cyfr, :s3, Keyword.put(prev, :prefix, "tenants/it"))
    on_exit(fn -> Application.put_env(:cyfr, :s3, prev) end)

    assert :ok = S3.put(ctx, ["data", "prefixed.txt"], "p")
    assert {:ok, "p"} = S3.get(ctx, ["data", "prefixed.txt"])

    # Without the prefix the object is elsewhere in the bucket.
    Application.put_env(:cyfr, :s3, prev)
    assert {:error, :not_found} = S3.get(ctx, ["data", "prefixed.txt"])
  end

  # MinIO answers 409 (BucketAlreadyOwnedByYou) when the bucket exists —
  # both outcomes leave a usable bucket.
  defp create_bucket!(endpoint) do
    url = "#{endpoint}/#{@bucket}"
    datetime = :calendar.universal_time()

    # Only the host: sign_v4 supplies X-Amz-Content-SHA256 for the body it
    # hashes, and a second copy signs the name twice (see Arca.Adapters.S3).
    headers = [{"host", URI.parse(url).authority}]

    signed =
      :aws_signature.sign_v4(
        @access,
        @secret,
        @region,
        "s3",
        datetime,
        "PUT",
        url,
        headers,
        "",
        # S3 does not re-encode its canonical URI; see Arca.Adapters.S3.
        [{:uri_encode_path, false}]
      )

    {:ok, %{status: status, body: body}} =
      Req.request(
        method: :put,
        url: url,
        headers: Enum.map(signed, fn {k, v} -> {to_string(k), to_string(v)} end),
        body: "",
        decode_body: false
      )

    unless status in [200, 409] do
      # The body carries S3's error code, which is the whole diagnosis:
      # SignatureDoesNotMatch, InvalidAccessKeyId and AccessDenied are all
      # 403 and have nothing to do with each other.
      raise "could not create MinIO bucket #{@bucket}: HTTP #{status} #{inspect(body)}"
    end
  end
end
