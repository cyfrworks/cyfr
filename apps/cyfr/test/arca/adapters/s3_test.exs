# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.S3Test do
  @moduledoc """
  Unit tests for `Arca.Adapters.S3`.

  Uses `Req`'s test plug feature to intercept HTTP calls and verify the
  adapter's request shape (URL, method, body, signed headers) without a
  real S3/MinIO service. Integration coverage against a real MinIO lives
  in `s3_minio_test.exs` (`mix test --only s3_integration`, the `s3-minio`
  CI job).
  """

  use ExUnit.Case, async: false

  alias Arca.Adapters.S3

  setup do
    Application.put_env(:cyfr, :s3,
      bucket: "test-bucket",
      region: "us-east-1",
      endpoint: "http://localhost:9000",
      access_key_id: "AKIATEST",
      secret_access_key: "secret/test+key",
      prefix: nil,
      path_style: true
    )

    # Stub Req so adapter HTTP calls are intercepted in-process.
    parent = self()

    Req.Test.stub(:s3, fn conn ->
      send(parent, {:req, conn.method, conn.request_path, conn.req_headers, read_body(conn)})

      case route(conn) do
        {:ok, status, body} ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(status, body)

        :not_found ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    Req.default_options(plug: {Req.Test, :s3})

    on_exit(fn ->
      Req.default_options([])
      Application.delete_env(:cyfr, :s3)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp read_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp route(conn) do
    case {conn.method, conn.request_path} do
      {"GET", "/test-bucket/athanors/ath_test/guest/exists.txt"} -> {:ok, 200, "hi"}
      {"PUT", _} -> {:ok, 200, ""}
      {"DELETE", _} -> {:ok, 204, ""}
      {"HEAD", "/test-bucket/athanors/ath_test/guest/exists.txt"} -> {:ok, 200, ""}
      {"GET", _} -> :not_found
      _ -> :not_found
    end
  end

  describe "put/3" do
    test "writes content with tenant key under the athanor root", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["config", "retention.json"], "{}")

      assert_received {:req, "PUT", path, headers, body}
      assert path == "/test-bucket/athanors/ath_test/config/retention.json"
      assert body == "{}"
      assert {"authorization", auth} = Enum.find(headers, fn {k, _} -> k == "authorization" end)
      assert auth =~ "AWS4-HMAC-SHA256"
      assert auth =~ "AKIATEST"
    end

    test "component paths key inside the athanor's components subtree", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["components", "catalysts", "x.wasm"], "wasm-bytes")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/athanors/ath_test/components/catalysts/x.wasm"
    end

    test "an athanor named after a reserved root keys under athanors/, not the root", %{ctx: ctx} do
      # An athanor id literally "components" must not collide with a global
      # root: every tenant key lives under the disjoint athanors/ root.
      odd_ctx = %{ctx | athanor_id: "components"}
      assert :ok = S3.put(odd_ctx, ["config", "b.json"], "{}")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/athanors/components/config/b.json"
    end

    test "seed media never reaches the bucket", %{ctx: ctx} do
      assert_raise ArgumentError, ~r/seed media/, fn ->
        S3.put(ctx, ["seed", "components", "catalysts", "x.wasm"], "wasm-bytes")
      end
    end

    test "the bare components root is the context's athanor's subtree", %{ctx: ctx} do
      # No raise — the root maps under athanors/{ctx}/components like any
      # other tenant path (this stub's listing answer is irrelevant here).
      _ = S3.list_recursive(ctx, ["components"])
      assert_received {:req, "GET", _path, _headers, _body}
    end

    test "cache paths bypass user scoping", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["cache", "oci", "blobs", "sha256", "abc"], "blob")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/cache/oci/blobs/sha256/abc"
    end

    test "applies CYFR_S3_PREFIX when configured", %{ctx: ctx} do
      Application.put_env(
        :cyfr,
        :s3,
        Application.get_env(:cyfr, :s3) |> Keyword.put(:prefix, "tenants/prod")
      )

      assert :ok = S3.put(ctx, ["guest", "x.txt"], "content")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/tenants/prod/athanors/ath_test/guest/x.txt"
    end
  end

  describe "get/2" do
    test "returns content on 200", %{ctx: ctx} do
      assert {:ok, "hi"} = S3.get(ctx, ["guest", "exists.txt"])
    end

    test "returns :not_found on 404", %{ctx: ctx} do
      assert {:error, :not_found} = S3.get(ctx, ["guest", "missing.txt"])
    end
  end

  describe "exists?/2" do
    test "returns true on 200", %{ctx: ctx} do
      assert S3.exists?(ctx, ["guest", "exists.txt"])
    end

    test "returns false on 404", %{ctx: ctx} do
      refute S3.exists?(ctx, ["guest", "missing.txt"])
    end
  end

  describe "delete/2" do
    test "deletes an existing object", %{ctx: ctx} do
      assert :ok = S3.delete(ctx, ["guest", "exists.txt"])
      assert_received {:req, "HEAD", "/test-bucket/athanors/ath_test/guest/exists.txt", _, _}
      assert_received {:req, "DELETE", "/test-bucket/athanors/ath_test/guest/exists.txt", _, _}
    end

    test "a missing key is :not_found, not a silent :ok", %{ctx: ctx} do
      # Real S3 answers 204 for a DELETE of a key that never existed; the
      # probe is what keeps this `{:error, :not_found}` like the Local adapter.
      assert {:error, :not_found} = S3.delete(ctx, ["guest", "whatever.txt"])
      refute_received {:req, "DELETE", _, _, _}
    end
  end

  describe "append/3" do
    test "extends the object in place, so get/2 returns the whole file", %{ctx: ctx} do
      assert :ok = S3.append(ctx, ["guest", "exists.txt"], "-more")

      # One path stays one object: the existing body is read and written back
      # extended, rather than a child object appearing under the path.
      assert_received {:req, "GET", "/test-bucket/athanors/ath_test/guest/exists.txt", _, _}

      assert_received {:req, "PUT", "/test-bucket/athanors/ath_test/guest/exists.txt", _,
                       "hi-more"}
    end

    test "creates the object when the path does not exist yet", %{ctx: ctx} do
      assert :ok = S3.append(ctx, ["guest", "audit", "2026-05-05.jsonl"], "event-1\n")

      assert_received {:req, "GET", "/test-bucket/athanors/ath_test/guest/audit/2026-05-05.jsonl",
                       _, _}

      assert_received {:req, "PUT", "/test-bucket/athanors/ath_test/guest/audit/2026-05-05.jsonl",
                       _, "event-1\n"}
    end

    test "refuses an object that would grow past the read ceiling", %{ctx: ctx} do
      oversized = :binary.copy("x", 5_242_881)

      assert {:error, :object_too_large} =
               S3.append(ctx, ["guest", "audit", "2026-05-05.jsonl"], oversized)

      refute_received {:req, "PUT", _, _, _}
    end
  end

  describe "ListObjectsV2 pagination" do
    # Serves a truncated first page and a final second page; the adapter must
    # follow NextContinuationToken (base64-ish, needs URL encoding) and merge
    # both pages.
    defp stub_paged_listing(parent) do
      page1 = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>true</IsTruncated>
        <Contents><Key>athanors/ath_test/guest/a.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/guest/b.txt</Key></Contents>
        <NextContinuationToken>tok+page/2==</NextContinuationToken>
      </ListBucketResult>
      """

      page2 = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>athanors/ath_test/guest/sub/c.txt</Key></Contents>
      </ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})

        cond do
          conn.method == "DELETE" ->
            Plug.Conn.send_resp(conn, 204, "")

          conn.method == "POST" and conn.query_string =~ "delete" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:delete_objects, body})
            Plug.Conn.send_resp(conn, 200, "<DeleteResult></DeleteResult>")

          conn.query_string =~ "continuation-token=tok%2Bpage%2F2%3D%3D" ->
            Plug.Conn.send_resp(conn, 200, page2)

          conn.query_string =~ "list-type=2" ->
            Plug.Conn.send_resp(conn, 200, page1)

          true ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)
    end

    test "list_recursive follows continuation tokens across pages", %{ctx: ctx} do
      stub_paged_listing(self())

      assert {:ok, leaves} = S3.list_recursive(ctx, ["guest"])

      assert Enum.sort(leaves) == [
               ["guest", "a.txt"],
               ["guest", "b.txt"],
               ["guest", "sub", "c.txt"]
             ]

      # Exactly two list requests: the initial page and the token follow-up.
      assert_received {:req, "GET", _, q1}
      assert_received {:req, "GET", _, q2}
      refute q1 =~ "continuation-token"
      assert q2 =~ "continuation-token=tok%2Bpage%2F2%3D%3D"
    end

    test "delete_tree removes keys from every page in one DeleteObjects batch", %{ctx: ctx} do
      stub_paged_listing(self())

      assert :ok = S3.delete_tree(ctx, ["guest"])

      # The bare-prefix object goes first, then one batched POST carrying
      # every key from both pages — not one DELETE per key.
      assert_received {:req, "DELETE", "/test-bucket/athanors/ath_test/guest", _}
      assert_received {:delete_objects, body}
      assert body =~ "athanors/ath_test/guest/a.txt"
      assert body =~ "athanors/ath_test/guest/b.txt"
      assert body =~ "athanors/ath_test/guest/sub/c.txt"
      refute_received {:delete_objects, _}
    end

    test "a repeated continuation token errors instead of looping", %{ctx: ctx} do
      parent = self()

      looping_page = """
      <ListBucketResult>
        <IsTruncated>true</IsTruncated>
        <Contents><Key>athanors/ath_test/guest/a.txt</Key></Contents>
        <NextContinuationToken>same-token</NextContinuationToken>
      </ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, looping_page)
      end)

      assert {:error, _} = S3.list_recursive(ctx, ["guest"])
    end
  end

  describe "component-prefix walks" do
    test "list_recursive returns logical leaves for an athanor's components subtree", %{ctx: ctx} do
      # The roster-driven tincture scan and the auto-indexer walk exactly
      # this prefix on an object-store deployment.
      parent = self()

      listing = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>athanors/ath_test/components/tinctures/local/dash/1.0.0/cyfr-manifest.json</Key></Contents>
        <Contents><Key>athanors/ath_test/components/tinctures/local/dash/1.0.0/index.html</Key></Contents>
      </ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, listing)
      end)

      assert {:ok, leaves} = S3.list_recursive(ctx, ["components", "tinctures"])

      assert Enum.sort(leaves) == [
               ["components", "tinctures", "local", "dash", "1.0.0", "cyfr-manifest.json"],
               ["components", "tinctures", "local", "dash", "1.0.0", "index.html"]
             ]

      assert_received {:req, "GET", _, query}
      assert URI.decode_query(query)["prefix"] =~ "athanors/ath_test/components/tinctures"
    end

    test "usage sums sizes under the athanor's components subtree", %{ctx: ctx} do
      parent = self()

      listing = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>athanors/ath_test/components/catalysts/local/x/1.0.0/catalyst.wasm</Key><Size>7</Size></Contents>
        <Contents><Key>athanors/ath_test/components/catalysts/local/x/1.0.0/cyfr-manifest.json</Key><Size>5</Size></Contents>
      </ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, listing)
      end)

      assert {:ok, %{files: 2, bytes: 12}} = S3.usage(ctx, ["components"])

      assert_received {:req, "GET", _, query}
      assert URI.decode_query(query)["prefix"] =~ "athanors/ath_test/components"
    end
  end

  describe "path traversal" do
    test "rejects '..' segments", %{ctx: ctx} do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        S3.get(ctx, ["..", "etc", "passwd"])
      end
    end

    test "rejects null bytes in segments", %{ctx: ctx} do
      assert_raise ArgumentError, ~r/null bytes/, fn ->
        S3.get(ctx, ["foo\0bar"])
      end
    end
  end
end
