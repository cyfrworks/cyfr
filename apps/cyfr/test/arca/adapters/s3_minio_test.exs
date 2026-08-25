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
      path = ["guest", "sig", name]
      content = "content of #{name}"

      assert :ok = S3.put(ctx, path, content)
      assert {:ok, ^content} = S3.get(ctx, path)
      assert S3.exists?(ctx, path)
      assert :ok = S3.delete(ctx, path)
      assert {:error, :not_found} = S3.get(ctx, path)
    end
  end

  test "listing callbacks agree with what was written", %{ctx: ctx} do
    :ok = S3.put(ctx, ["guest", "walk", "a.txt"], "a")
    :ok = S3.put(ctx, ["guest", "walk", "b.txt"], "bb")
    :ok = S3.put(ctx, ["guest", "walk", "sub", "c.txt"], "ccc")

    assert {:ok, entries} = S3.list_typed(ctx, ["guest", "walk"])
    assert Enum.sort(entries) == [{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}]

    assert {:error, :enotdir} = S3.list_typed(ctx, ["guest", "walk", "a.txt"])
    assert {:ok, []} = S3.list_typed(ctx, ["guest", "walk", "nothing"])

    assert {:ok, leaves} = S3.list_recursive(ctx, ["guest", "walk"])

    assert Enum.sort(leaves) == [
             ["guest", "walk", "a.txt"],
             ["guest", "walk", "b.txt"],
             ["guest", "walk", "sub", "c.txt"]
           ]

    assert {:ok, %{files: 3, bytes: 6}} = S3.usage(ctx, ["guest", "walk"])

    assert {:ok, pairs} = S3.read_subtree(ctx, ["guest", "walk"])

    assert Enum.sort(pairs) == [
             {["a.txt"], "a"},
             {["b.txt"], "bb"},
             {["sub", "c.txt"], "ccc"}
           ]

    assert :ok = S3.delete_tree(ctx, ["guest", "walk"])
    assert {:ok, []} = S3.list_recursive(ctx, ["guest", "walk"])
  end

  test "append extends in place and delete_tree's batch really deletes", %{ctx: ctx} do
    path = ["guest", "log", "events.jsonl"]
    assert :ok = S3.append(ctx, path, "one\n")
    assert :ok = S3.append(ctx, path, "two\n")
    assert {:ok, "one\ntwo\n"} = S3.get(ctx, path)

    # The DeleteObjects batch is Content-MD5-signed — a real service
    # rejects a bad digest, which no stub can prove.
    assert :ok = S3.delete_tree(ctx, ["guest", "log"])
    refute S3.exists?(ctx, path)
  end

  test "a configured key prefix scopes every object", %{ctx: ctx} do
    prev = Application.fetch_env!(:cyfr, :s3)
    Application.put_env(:cyfr, :s3, Keyword.put(prev, :prefix, "tenants/it"))
    on_exit(fn -> Application.put_env(:cyfr, :s3, prev) end)

    assert :ok = S3.put(ctx, ["guest", "prefixed.txt"], "p")
    assert {:ok, "p"} = S3.get(ctx, ["guest", "prefixed.txt"])

    # Without the prefix the object is elsewhere in the bucket.
    Application.put_env(:cyfr, :s3, prev)
    assert {:error, :not_found} = S3.get(ctx, ["guest", "prefixed.txt"])
  end

  # MinIO answers 409 (BucketAlreadyOwnedByYou) when the bucket exists —
  # both outcomes leave a usable bucket.
  defp create_bucket!(endpoint) do
    url = "#{endpoint}/#{@bucket}"
    datetime = :calendar.universal_time()

    headers = [
      {"host", URI.parse(url).authority},
      {"x-amz-content-sha256", Base.encode16(:crypto.hash(:sha256, ""), case: :lower)}
    ]

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
        []
      )

    {:ok, %{status: status}} =
      Req.request(
        method: :put,
        url: url,
        headers: Enum.map(signed, fn {k, v} -> {to_string(k), to_string(v)} end),
        body: "",
        decode_body: false
      )

    unless status in [200, 409] do
      raise "could not create MinIO bucket #{@bucket}: HTTP #{status}"
    end
  end
end
