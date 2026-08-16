# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.S3Test do
  @moduledoc """
  Unit tests for `Arca.Adapters.S3`.

  Uses `Req`'s test plug feature to intercept HTTP calls and verify the
  adapter's request shape (URL, method, body, signed headers) without a
  real S3/MinIO service. Integration coverage against a MinIO service
  container is added separately in CI.
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
      {"GET", "/test-bucket/data/ath_test/exists.txt"} -> {:ok, 200, "hi"}
      {"PUT", _} -> {:ok, 200, ""}
      {"DELETE", _} -> {:ok, 204, ""}
      {"HEAD", "/test-bucket/data/ath_test/exists.txt"} -> {:ok, 200, ""}
      {"GET", _} -> :not_found
      _ -> :not_found
    end
  end

  describe "put/3" do
    test "writes content with user-scoped key under the data/ root", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["builds", "build_1.json"], "{}")

      assert_received {:req, "PUT", path, headers, body}
      assert path == "/test-bucket/data/ath_test/builds/build_1.json"
      assert body == "{}"
      assert {"authorization", auth} = Enum.find(headers, fn {k, _} -> k == "authorization" end)
      assert auth =~ "AWS4-HMAC-SHA256"
      assert auth =~ "AKIATEST"
    end

    test "components paths bypass user scoping (no data/ prefix)", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["components", "catalysts", "x.wasm"], "wasm-bytes")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/components/catalysts/x.wasm"
    end

    test "an athanor named after a reserved root keys under data/, not the root", %{ctx: ctx} do
      # An athanor id literally "components" must not collide with the
      # component store: its tenant data lives under the disjoint data/ root.
      odd_ctx = %{ctx | athanor_id: "components"}
      assert :ok = S3.put(odd_ctx, ["builds", "b.json"], "{}")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/data/components/builds/b.json"
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

      assert :ok = S3.put(ctx, ["reports", "x.txt"], "content")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/tenants/prod/data/ath_test/reports/x.txt"
    end
  end

  describe "get/2" do
    test "returns content on 200", %{ctx: ctx} do
      assert {:ok, "hi"} = S3.get(ctx, ["exists.txt"])
    end

    test "returns :not_found on 404", %{ctx: ctx} do
      assert {:error, :not_found} = S3.get(ctx, ["missing.txt"])
    end
  end

  describe "exists?/2" do
    test "returns true on 200", %{ctx: ctx} do
      assert S3.exists?(ctx, ["exists.txt"])
    end

    test "returns false on 404", %{ctx: ctx} do
      refute S3.exists?(ctx, ["missing.txt"])
    end
  end

  describe "delete/2" do
    test "returns :ok on 204", %{ctx: ctx} do
      assert :ok = S3.delete(ctx, ["whatever.txt"])
    end
  end

  describe "append/3" do
    test "writes a new immutable object per call (multi-object pattern)", %{ctx: ctx} do
      assert :ok = S3.append(ctx, ["audit", "2026-05-05.jsonl"], "event-1\n")
      assert :ok = S3.append(ctx, ["audit", "2026-05-05.jsonl"], "event-2\n")

      assert_received {:req, "PUT", path1, _, "event-1\n"}
      assert_received {:req, "PUT", path2, _, "event-2\n"}

      # Both writes go under the same prefix with monotonic suffixes.
      assert String.starts_with?(path1, "/test-bucket/data/ath_test/audit/2026-05-05.jsonl/")
      assert String.starts_with?(path2, "/test-bucket/data/ath_test/audit/2026-05-05.jsonl/")
      assert path1 != path2
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
        <Contents><Key>data/ath_test/tree/a.txt</Key></Contents>
        <Contents><Key>data/ath_test/tree/b.txt</Key></Contents>
        <NextContinuationToken>tok+page/2==</NextContinuationToken>
      </ListBucketResult>
      """

      page2 = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>data/ath_test/tree/sub/c.txt</Key></Contents>
      </ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})

        cond do
          conn.method == "DELETE" ->
            Plug.Conn.send_resp(conn, 204, "")

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

      assert {:ok, leaves} = S3.list_recursive(ctx, ["tree"])

      assert Enum.sort(leaves) == [
               ["tree", "a.txt"],
               ["tree", "b.txt"],
               ["tree", "sub", "c.txt"]
             ]

      # Exactly two list requests: the initial page and the token follow-up.
      assert_received {:req, "GET", _, q1}
      assert_received {:req, "GET", _, q2}
      refute q1 =~ "continuation-token"
      assert q2 =~ "continuation-token=tok%2Bpage%2F2%3D%3D"
    end

    test "delete_tree removes keys from every page", %{ctx: ctx} do
      stub_paged_listing(self())

      assert :ok = S3.delete_tree(ctx, ["tree"])

      # Drain the two GET pages, then expect one DELETE per key on both pages.
      assert_received {:req, "GET", _, _}
      assert_received {:req, "GET", _, _}
      assert_received {:req, "DELETE", "/test-bucket/data/ath_test/tree/a.txt", _}
      assert_received {:req, "DELETE", "/test-bucket/data/ath_test/tree/b.txt", _}
      assert_received {:req, "DELETE", "/test-bucket/data/ath_test/tree/sub/c.txt", _}
    end

    test "a repeated continuation token errors instead of looping", %{ctx: ctx} do
      parent = self()

      looping_page = """
      <ListBucketResult>
        <IsTruncated>true</IsTruncated>
        <Contents><Key>data/ath_test/tree/a.txt</Key></Contents>
        <NextContinuationToken>same-token</NextContinuationToken>
      </ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, looping_page)
      end)

      assert {:error, _} = S3.list_recursive(ctx, ["tree"])
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
