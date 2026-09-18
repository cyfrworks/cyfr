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
          # Every object and every write answers an ETag, as a store does.
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.put_resp_header("etag", ~s("etag-of-#{conn.method}"))
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

  # One request header's value, `nil` when the request did not carry it.
  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp route(conn) do
    case {conn.method, conn.request_path} do
      {"GET", "/test-bucket/athanors/ath_test/data/exists.txt"} -> {:ok, 200, "hi"}
      {"PUT", _} -> {:ok, 200, ""}
      {"DELETE", _} -> {:ok, 204, ""}
      {"HEAD", "/test-bucket/athanors/ath_test/data/exists.txt"} -> {:ok, 200, ""}
      {"GET", _} -> :not_found
      _ -> :not_found
    end
  end

  describe "put/3" do
    test "writes content with tenant key under the athanor root", %{ctx: ctx} do
      assert :ok = S3.put(ctx, ["data", "notes.json"], "{}")

      assert_received {:req, "PUT", path, headers, body}
      assert path == "/test-bucket/athanors/ath_test/data/notes.json"
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
      assert :ok = S3.put(odd_ctx, ["data", "b.json"], "{}")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/athanors/components/data/b.json"
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

      assert :ok = S3.put(ctx, ["data", "x.txt"], "content")

      assert_received {:req, "PUT", path, _headers, _body}
      assert path == "/test-bucket/tenants/prod/athanors/ath_test/data/x.txt"
    end
  end

  describe "get/2" do
    test "returns content on 200", %{ctx: ctx} do
      assert {:ok, "hi"} = S3.get(ctx, ["data", "exists.txt"])
    end

    test "returns :not_found on 404", %{ctx: ctx} do
      assert {:error, :not_found} = S3.get(ctx, ["data", "missing.txt"])
    end
  end

  describe "exists?/2" do
    test "returns true on 200", %{ctx: ctx} do
      assert S3.exists?(ctx, ["data", "exists.txt"])
    end

    test "returns false on 404", %{ctx: ctx} do
      refute S3.exists?(ctx, ["data", "missing.txt"])
    end
  end

  describe "delete/2" do
    test "deletes an existing object", %{ctx: ctx} do
      assert :ok = S3.delete(ctx, ["data", "exists.txt"])
      assert_received {:req, "HEAD", "/test-bucket/athanors/ath_test/data/exists.txt", _, _}
      assert_received {:req, "DELETE", "/test-bucket/athanors/ath_test/data/exists.txt", _, _}
    end

    test "a missing key is :not_found, not a silent :ok", %{ctx: ctx} do
      # Real S3 answers 204 for a DELETE of a key that never existed; the
      # probe is what keeps this `{:error, :not_found}` like the Local adapter.
      assert {:error, :not_found} = S3.delete(ctx, ["data", "whatever.txt"])
      refute_received {:req, "DELETE", _, _, _}
    end
  end

  describe "append/3" do
    test "extends the object in place, so get/2 returns the whole file", %{ctx: ctx} do
      assert :ok = S3.append(ctx, ["data", "exists.txt"], "-more")

      # One path stays one object: the existing body is read and written back
      # extended, rather than a child object appearing under the path.
      assert_received {:req, "GET", "/test-bucket/athanors/ath_test/data/exists.txt", _, _}

      assert_received {:req, "PUT", "/test-bucket/athanors/ath_test/data/exists.txt", _,
                       "hi-more"}
    end

    test "creates the object when the path does not exist yet", %{ctx: ctx} do
      assert :ok = S3.append(ctx, ["data", "audit", "2026-05-05.jsonl"], "event-1\n")

      assert_received {:req, "GET", "/test-bucket/athanors/ath_test/data/audit/2026-05-05.jsonl",
                       _, _}

      assert_received {:req, "PUT", "/test-bucket/athanors/ath_test/data/audit/2026-05-05.jsonl",
                       _, "event-1\n"}
    end

    test "refuses an object that would grow past the read ceiling", %{ctx: ctx} do
      oversized = :binary.copy("x", 5_242_881)

      assert {:error, :object_too_large} =
               S3.append(ctx, ["data", "audit", "2026-05-05.jsonl"], oversized)

      refute_received {:req, "PUT", _, _, _}
    end

    test "writes back under If-Match on the ETag it read, If-None-Match on a create",
         %{ctx: ctx} do
      assert :ok = S3.append(ctx, ["data", "exists.txt"], "-more")
      assert_received {:req, "PUT", _, headers, "hi-more"}
      assert header(headers, "if-match") == ~s("etag-of-GET")
      assert header(headers, "if-none-match") == nil

      assert :ok = S3.append(ctx, ["data", "fresh.jsonl"], "one\n")
      assert_received {:req, "PUT", _, headers, "one\n"}
      assert header(headers, "if-none-match") == "*"
      assert header(headers, "if-match") == nil
    end

    test "a lost round reads again and lands on what the winner wrote", %{ctx: ctx} do
      # The first write back loses to a concurrent append; the object the
      # second read answers carries the winner's line.
      rounds = start_supervised!({Agent, fn -> 0 end})
      parent = self()

      Req.Test.stub(:s3, fn conn ->
        body = read_body(conn)
        send(parent, {:req, conn.method, conn.request_path, conn.req_headers, body})
        round = Agent.get(rounds, & &1)

        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("v#{round}"))
            |> Plug.Conn.send_resp(200, String.duplicate("winner\n", round))

          "PUT" ->
            if round == 0 do
              Agent.update(rounds, &(&1 + 1))
              Plug.Conn.send_resp(conn, 412, "<Error><Code>PreconditionFailed</Code></Error>")
            else
              conn |> Plug.Conn.put_resp_header("etag", ~s("v2")) |> Plug.Conn.send_resp(200, "")
            end
        end
      end)

      assert :ok = S3.append(ctx, ["data", "log.jsonl"], "mine\n")

      assert_received {:req, "PUT", _, first, "mine\n"}
      assert header(first, "if-match") == ~s("v0")
      assert_received {:req, "PUT", _, second, "winner\nmine\n"}
      assert header(second, "if-match") == ~s("v1")
      refute_received {:req, "PUT", _, _, _}
    end

    test "a 412 storm exhausts the bound and answers :precondition_failed, not a loop",
         %{ctx: ctx} do
      parent = self()

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.req_headers, read_body(conn)})

        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("moving"))
            |> Plug.Conn.send_resp(200, "x")

          "PUT" ->
            Plug.Conn.send_resp(conn, 412, "<Error><Code>PreconditionFailed</Code></Error>")
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :precondition_failed} = S3.append(ctx, ["data", "log.jsonl"], "mine\n")
        end)

      assert log =~ "still losing after 5 attempts"

      # Five reads, five conditional writes, and then it stops.
      for _ <- 1..5 do
        assert_received {:req, "GET", _, _, _}
        assert_received {:req, "PUT", _, _, "xmine\n"}
      end

      refute_received {:req, _, _, _, _}
    end

    test "an unknown outcome is final: an append that may have landed is not sent twice",
         %{ctx: ctx} do
      parent = self()

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.req_headers, read_body(conn)})

        case conn.method do
          "GET" -> Plug.Conn.send_resp(conn, 404, "")
          "PUT" -> Req.Test.transport_error(conn, :closed)
        end
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unknown} = S3.append(ctx, ["data", "log.jsonl"], "mine\n")
      end)

      assert_received {:req, "PUT", _, _, "mine\n"}
      refute_received {:req, "PUT", _, _, _}
    end

    test "an object read without an ETag is refused, never written back unconditionally",
         %{ctx: ctx} do
      parent = self()

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.req_headers, read_body(conn)})
        Plug.Conn.send_resp(conn, 200, "no etag here")
      end)

      assert {:error, :unsupported} = S3.append(ctx, ["data", "log.jsonl"], "mine\n")
      refute_received {:req, "PUT", _, _, _}
    end
  end

  describe "put_if_none_match/3 and put_if_match/4" do
    # One answer for every request, recording each as the setup's stub does.
    defp stub_answer(status, body \\ "", resp_headers \\ []) do
      parent = self()

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.req_headers, read_body(conn)})

        resp_headers
        |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
        |> Plug.Conn.send_resp(status, body)
      end)
    end

    test "a create sends If-None-Match: * inside the signature and answers the ETag",
         %{ctx: ctx} do
      assert {:ok, ~s("etag-of-PUT")} = S3.put_if_none_match(ctx, ["data", "unit"], ["by", "tes"])

      assert_received {:req, "PUT", "/test-bucket/athanors/ath_test/data/unit", headers, "bytes"}
      assert header(headers, "if-none-match") == "*"
      assert header(headers, "authorization") =~ ~r/SignedHeaders=[^,]*if-none-match/
    end

    test "a replace sends the precondition verbatim as If-Match, signed", %{ctx: ctx} do
      assert {:ok, ~s("etag-of-PUT")} = S3.put_if_match(ctx, ["data", "unit"], "v2", ~s("abc123"))

      assert_received {:req, "PUT", _, headers, "v2"}
      assert header(headers, "if-match") == ~s("abc123")
      assert header(headers, "authorization") =~ ~r/SignedHeaders=[^,]*if-match/
    end

    test "412 is :exists for a create and :precondition_failed for a replace", %{ctx: ctx} do
      stub_answer(412, "<Error><Code>PreconditionFailed</Code></Error>")

      assert {:error, :exists} = S3.put_if_none_match(ctx, ["data", "unit"], "x")
      assert {:error, :precondition_failed} = S3.put_if_match(ctx, ["data", "unit"], "x", ~s("e"))
    end

    test "409, a conditional write racing another, is the same definite conflict", %{ctx: ctx} do
      stub_answer(409, "<Error><Code>ConditionalRequestConflict</Code></Error>")

      assert {:error, :exists} = S3.put_if_none_match(ctx, ["data", "unit"], "x")
      assert {:error, :precondition_failed} = S3.put_if_match(ctx, ["data", "unit"], "x", ~s("e"))
    end

    test "404 on a conditional replace is :missing; a missing bucket is not", %{ctx: ctx} do
      stub_answer(404, "<Error><Code>NoSuchKey</Code></Error>")
      assert {:error, :missing} = S3.put_if_match(ctx, ["data", "unit"], "x", ~s("e"))

      stub_answer(404, "<Error><Code>NoSuchBucket</Code></Error>")

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:s3_error, 404}} = S3.put_if_match(ctx, ["data", "unit"], "x", ~s("e"))
        assert {:error, {:s3_error, 404}} = S3.put_if_none_match(ctx, ["data", "unit"], "x")
      end)
    end

    test "a precondition no header can carry is never sent: the key is probed", %{ctx: ctx} do
      for unsendable <- [:not_an_etag, "", "line\r\nx-injected: 1", <<0xFF>>] do
        assert {:error, :precondition_failed} =
                 S3.put_if_match(ctx, ["data", "exists.txt"], "x", unsendable)

        assert {:error, :missing} = S3.put_if_match(ctx, ["data", "absent.txt"], "x", unsendable)
      end

      refute_received {:req, "PUT", _, _, _}
    end

    test "a store that cannot make the write conditional is :unsupported", %{ctx: ctx} do
      stub_answer(501, "<Error><Code>NotImplemented</Code></Error>")
      assert {:error, :unsupported} = S3.put_if_none_match(ctx, ["data", "unit"], "x")
      assert {:error, :unsupported} = S3.put_if_match(ctx, ["data", "unit"], "x", ~s("e"))

      # A write answered without an ETag cannot be followed conditionally.
      stub_answer(200)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unsupported} = S3.put_if_none_match(ctx, ["data", "unit"], "x")
      end)
    end

    test "a refusal stays a refusal; a 5xx that may have applied is :unknown", %{ctx: ctx} do
      ExUnit.CaptureLog.capture_log(fn ->
        stub_answer(403, "<Error><Code>AccessDenied</Code></Error>")
        assert {:error, {:s3_error, 403}} = S3.put_if_none_match(ctx, ["data", "unit"], "x")

        stub_answer(503, "<Error><Code>SlowDown</Code></Error>")
        assert {:error, {:s3_error, 503}} = S3.put_if_match(ctx, ["data", "unit"], "x", ~s("e"))

        for status <- [500, 502, 504] do
          stub_answer(status, "<Error><Code>InternalError</Code></Error>")
          assert {:error, :unknown} = S3.put_if_none_match(ctx, ["data", "unit"], "x")
          assert {:error, :unknown} = S3.put_if_match(ctx, ["data", "unit"], "x", ~s("e"))
        end
      end)
    end

    test "seed media never reaches the bucket", %{ctx: ctx} do
      for call <- [
            fn -> S3.put_if_none_match(ctx, ["seed", "components", "x"], "x") end,
            fn -> S3.put_if_match(ctx, ["seed", "components", "x"], "x", ~s("e")) end
          ] do
        assert_raise ArgumentError, ~r/seed media/, call
      end

      refute_received {:req, _, _, _, _}
    end
  end

  describe "a connection that fails around a conditional write" do
    # A listener that reads one whole request and then resets the
    # connection: the store may have committed, and no answer comes back.
    defp endpoint_resetting_after_the_request do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)
      parent = self()

      acceptor =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 10_000)
          request = read_request(socket, "")
          send(parent, {:request_read, request})
          :ok = :inet.setopts(socket, linger: {true, 0})
          :gen_tcp.close(socket)
        end)

      on_exit(fn ->
        Process.exit(acceptor, :kill)
        :gen_tcp.close(listener)
      end)

      port
    end

    defp read_request(socket, acc) do
      with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
           [_, length] <- Regex.run(~r/content-length: (\d+)/i, head),
           true <- byte_size(body) >= String.to_integer(length) do
        acc
      else
        _ ->
          {:ok, more} = :gen_tcp.recv(socket, 0, 10_000)
          read_request(socket, acc <> more)
      end
    end

    defp point_at(port) do
      Req.default_options([])

      Application.put_env(
        :cyfr,
        :s3,
        Application.get_env(:cyfr, :s3) |> Keyword.put(:endpoint, "http://127.0.0.1:#{port}")
      )
    end

    test "a reset after the request was sent is :unknown, for a create and a replace",
         %{ctx: ctx} do
      for write <- [
            fn -> S3.put_if_none_match(ctx, ["data", "unit"], "committed?") end,
            fn -> S3.put_if_match(ctx, ["data", "unit"], "committed?", ~s("e")) end
          ] do
        point_at(endpoint_resetting_after_the_request())

        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :unknown} = write.()
        end)

        # The whole request, body included, had reached the store.
        assert_received {:request_read, request}
        assert request =~ "PUT /test-bucket/athanors/ath_test/data/unit"
        assert request =~ "committed?"
      end
    end

    test "a connection that was never made is the store unreachable, not :unknown",
         %{ctx: ctx} do
      {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)
      point_at(port)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Req.TransportError{reason: :econnrefused}} =
                 S3.put_if_none_match(ctx, ["data", "unit"], "x")
      end)
    end
  end

  describe "list_prefix/2" do
    test "answers the keys under prefix/, markers dropped; one object; nothing", %{ctx: ctx} do
      parent = self()

      listing = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>athanors/ath_test/data/reg/u1</Key></Contents>
        <Contents><Key>athanors/ath_test/data/reg/deep/u2</Key></Contents>
        <Contents><Key>athanors/ath_test/data/reg/marker/</Key></Contents>
      </ListBucketResult>
      """

      empty = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})
        prefix = URI.decode_query(conn.query_string)["prefix"]

        cond do
          prefix == "athanors/ath_test/data/reg/" -> Plug.Conn.send_resp(conn, 200, listing)
          is_binary(prefix) -> Plug.Conn.send_resp(conn, 200, empty)
          conn.request_path =~ ~r{/data/reg/u1$} -> Plug.Conn.send_resp(conn, 200, "")
          true -> Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      assert {:ok, keys} = S3.list_prefix(ctx, ["data", "reg"])
      assert Enum.sort(keys) == [["data", "reg", "deep", "u2"], ["data", "reg", "u1"]]

      assert {:ok, [["data", "reg", "u1"]]} = S3.list_prefix(ctx, ["data", "reg", "u1"])
      assert {:ok, []} = S3.list_prefix(ctx, ["data", "reg", "absent"])
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
        <Contents><Key>athanors/ath_test/data/a.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/data/b.txt</Key></Contents>
        <NextContinuationToken>tok+page/2==</NextContinuationToken>
      </ListBucketResult>
      """

      page2 = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>athanors/ath_test/data/sub/c.txt</Key></Contents>
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

      assert {:ok, leaves} = S3.list_recursive(ctx, ["data"])

      assert Enum.sort(leaves) == [
               ["data", "a.txt"],
               ["data", "b.txt"],
               ["data", "sub", "c.txt"]
             ]

      # Exactly two list requests: the initial page and the token follow-up.
      assert_received {:req, "GET", _, q1}
      assert_received {:req, "GET", _, q2}
      refute q1 =~ "continuation-token"
      assert q2 =~ "continuation-token=tok%2Bpage%2F2%3D%3D"
    end

    test "delete_tree removes keys from every page in one DeleteObjects batch", %{ctx: ctx} do
      stub_paged_listing(self())

      assert :ok = S3.delete_tree(ctx, ["data"])

      # The bare-prefix object goes first, then one batched POST carrying
      # every key from both pages — not one DELETE per key.
      assert_received {:req, "DELETE", "/test-bucket/athanors/ath_test/data", _}
      assert_received {:delete_objects, body}
      assert body =~ "athanors/ath_test/data/a.txt"
      assert body =~ "athanors/ath_test/data/b.txt"
      assert body =~ "athanors/ath_test/data/sub/c.txt"
      refute_received {:delete_objects, _}
    end

    test "a repeated continuation token errors instead of looping", %{ctx: ctx} do
      parent = self()

      looping_page = """
      <ListBucketResult>
        <IsTruncated>true</IsTruncated>
        <Contents><Key>athanors/ath_test/data/a.txt</Key></Contents>
        <NextContinuationToken>same-token</NextContinuationToken>
      </ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        send(parent, {:req, conn.method, conn.request_path, conn.query_string})
        Plug.Conn.send_resp(conn, 200, looping_page)
      end)

      assert {:error, _} = S3.list_recursive(ctx, ["data"])
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
