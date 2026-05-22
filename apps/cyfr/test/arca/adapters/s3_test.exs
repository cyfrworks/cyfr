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
  alias Sanctum.Context

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
      {"GET", "/test-bucket/testns/default/testns/exists.txt"} -> {:ok, 200, "hi"}
      {"PUT", _} -> {:ok, 200, ""}
      {"DELETE", _} -> {:ok, 204, ""}
      {"HEAD", "/test-bucket/testns/default/testns/exists.txt"} -> {:ok, 200, ""}
      {"GET", _} -> :not_found
      _ -> :not_found
    end
  end

  describe "put/3" do
    test "writes content with user-scoped key", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["builds", "build_1.json"], "{}")

      assert_received {:req, "PUT", path, headers, body}
      assert path == "/test-bucket/testns/default/testns/builds/build_1.json"
      assert body == "{}"
      assert {"authorization", auth} = Enum.find(headers, fn {k, _} -> k == "authorization" end)
      assert auth =~ "AWS4-HMAC-SHA256"
      assert auth =~ "AKIATEST"
    end

    test "components paths bypass user scoping", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["components", "catalysts", "x.wasm"], "wasm-bytes")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/components/catalysts/x.wasm"
    end

    test "cache paths bypass user scoping", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["cache", "oci", "blobs", "sha256", "abc"], "blob")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/cache/oci/blobs/sha256/abc"
    end

    test "applies CYFR_S3_PREFIX when configured", %{ctx: ctx} do
      Application.put_env(:cyfr, :s3,
        Application.get_env(:cyfr, :s3) |> Keyword.put(:prefix, "tenants/prod")
      )

      assert :ok = S3.put(ctx, ["data", "x.txt"], "content")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/tenants/prod/testns/default/testns/data/x.txt"
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
      assert String.starts_with?(path1, "/test-bucket/testns/default/testns/audit/2026-05-05.jsonl/")
      assert String.starts_with?(path2, "/test-bucket/testns/default/testns/audit/2026-05-05.jsonl/")
      assert path1 != path2
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
