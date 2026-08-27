# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.ContractTest do
  @moduledoc """
  One contract, asserted against both adapters — with one shared assertion
  body per case, so an invariant cannot be added to one adapter's suite and
  forgotten in the other's.

  The adapters disagreed on several answers before this file existed: a
  path that is a file answered `{:error, :enotdir}` on one and `{:ok, []}`
  on the other; `exists?` counted directories on one; a missing-key delete
  was a silent `:ok`; a console-written directory marker (`foo/`) was a
  zero-byte file in one walk and nothing in the other. Every case here is
  a question both adapters must answer identically. (`list/2` no longer
  appears here: the behaviour dropped the callback — names are derived from
  `list_typed/2` in the `Arca` facade, one walk, nothing to diverge.)

  The shared fixture tree under `guest/`: `a.txt` = "a", `b.txt` = "b",
  `sub/c.txt` = "c" (and, on S3, a `marker/` directory-marker object).
  """

  use ExUnit.Case, async: false

  alias Arca.Adapters.Local
  alias Arca.Adapters.S3

  # ---------------------------------------------------------------------------
  # The shared contract — one body per case, called from both describes.
  # ---------------------------------------------------------------------------

  defp contract_put_get_roundtrip(adapter, ctx) do
    assert :ok = adapter.put(ctx, ["guest", "rt.txt"], "round-trip")
    assert {:ok, "round-trip"} = adapter.get(ctx, ["guest", "rt.txt"])
  end

  # Both adapters create on first append and concatenate on the next. The
  # ceilings diverge by design — S3's read-modify-write refuses past
  # `:object_too_large` while Local's O_APPEND is unbounded — and each
  # adapter's own suite asserts its side; concurrency semantics diverge the
  # same way (last-writer-wins on S3) and are likewise not a shared case.
  defp contract_append_roundtrip(adapter, ctx) do
    assert :ok = adapter.append(ctx, ["guest", "log.jsonl"], "one\n")
    assert :ok = adapter.append(ctx, ["guest", "log.jsonl"], "two\n")
    assert {:ok, "one\ntwo\n"} = adapter.get(ctx, ["guest", "log.jsonl"])
  end

  defp contract_dir_vs_file(adapter, ctx, extra_dirs) do
    assert {:ok, entries} = adapter.list_typed(ctx, ["guest"])

    expected =
      Enum.sort([{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}] ++ extra_dirs)

    assert Enum.sort(entries) == expected
  end

  defp contract_file_is_not_a_directory(adapter, ctx) do
    assert {:error, :enotdir} = adapter.list_typed(ctx, ["guest", "a.txt"])
  end

  # A directory is not a readable object: S3 has no key there and answers
  # :not_found — Local used to leak a raw :eisdir for the same question.
  defp contract_get_directory_is_not_found(adapter, ctx) do
    assert {:error, :not_found} = adapter.get(ctx, ["guest", "sub"])
  end

  defp contract_serve_missing_and_directory_not_found(adapter, ctx) do
    conn = Plug.Test.conn(:get, "/")
    assert {:error, :not_found} = adapter.serve_to_conn(conn, ctx, ["guest", "missing.txt"], [])
    assert {:error, :not_found} = adapter.serve_to_conn(conn, ctx, ["guest", "sub"], [])
  end

  defp contract_empty_listing(adapter, ctx) do
    assert {:ok, []} = adapter.list_typed(ctx, ["guest", "nothing-here"])
  end

  defp contract_exists_files_only(adapter, ctx) do
    assert adapter.exists?(ctx, ["guest", "a.txt"])
    refute adapter.exists?(ctx, ["guest"])
    refute adapter.exists?(ctx, ["guest", "missing.txt"])
  end

  defp contract_delete(adapter, ctx) do
    assert {:error, :not_found} = adapter.delete(ctx, ["guest", "missing.txt"])
    assert :ok = adapter.delete(ctx, ["guest", "a.txt"])
  end

  defp contract_delete_tree_object_at_path(adapter, ctx) do
    assert :ok = adapter.delete_tree(ctx, ["guest", "a.txt"])
  end

  # Tree deletion is idempotent — "make this subtree not exist" already
  # holds for a missing tree. `:not_found` is delete/2's answer for a
  # missing single object, never delete_tree/2's.
  defp contract_delete_tree_missing_is_ok(adapter, ctx) do
    assert :ok = adapter.delete_tree(ctx, ["guest", "nothing-here"])
  end

  defp contract_list_recursive(adapter, ctx) do
    assert {:ok, leaves} = adapter.list_recursive(ctx, ["guest"])

    assert Enum.sort(leaves) == [
             ["guest", "a.txt"],
             ["guest", "b.txt"],
             ["guest", "sub", "c.txt"]
           ]
  end

  defp contract_usage(adapter, ctx) do
    # Three files, one byte each — a directory marker is not a file and a
    # directory has no bytes, on either adapter.
    assert {:ok, %{files: 3, bytes: 3}} = adapter.usage(ctx, ["guest"])
  end

  # read_subtree is no adapter callback — one shared algorithm over
  # list_recursive + get (`Arca.Storage.read_subtree_via/4`). Run here per
  # adapter anyway: the shared code must answer identically over each
  # adapter's listing and read semantics, file-path contract included.
  defp contract_read_subtree(adapter, ctx) do
    assert {:ok, pairs} = Arca.Storage.read_subtree_via(adapter, ctx, ["guest"])

    assert Enum.sort(pairs) == [
             {["a.txt"], "a"},
             {["b.txt"], "b"},
             {["sub", "c.txt"], "c"}
           ]

    # A file is not a subtree; a missing prefix is honestly empty.
    assert {:error, :enotdir} = Arca.Storage.read_subtree_via(adapter, ctx, ["guest", "a.txt"])
    assert {:ok, []} = Arca.Storage.read_subtree_via(adapter, ctx, ["guest", "nope"])
  end

  # A 300-byte name used to store fine on S3 (1024-byte keys) and
  # `:enametoolong` on Local — exactly the divergence this file exists to
  # prevent. Both adapters now refuse it identically at validation, before
  # any I/O.
  defp contract_overlong_segment_refused(adapter, ctx) do
    long = String.duplicate("a", 300)

    assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
      adapter.put(ctx, ["guest", long], "x")
    end

    assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
      adapter.get(ctx, ["guest", long])
    end
  end

  # Seed media is read-only at every adapter, with ONE message — the two
  # adapters once refused with different mechanisms and different words
  # (`Arca.Storage.refuse_seed_write!/1` is now the single spelling).
  defp contract_seed_writes_refused(adapter, ctx) do
    for call <- [
          fn -> adapter.put(ctx, ["seed", "components", "x.txt"], "x") end,
          fn -> adapter.append(ctx, ["seed", "components", "x.txt"], "x") end,
          fn -> adapter.delete(ctx, ["seed", "components", "x.txt"]) end,
          fn -> adapter.delete_tree(ctx, ["seed", "components"]) end
        ] do
      assert_raise ArgumentError, ~r/seed media is read-only/, call
    end
  end

  # Traversal segments refuse identically at validation, before any I/O —
  # the same denylist on every adapter.
  defp contract_traversal_refused(adapter, ctx) do
    assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
      adapter.get(ctx, ["guest", "..", "escape.txt"])
    end

    assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
      adapter.put(ctx, ["guest", "..", "escape.txt"], "x")
    end
  end

  # ---------------------------------------------------------------------------
  # Local
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.Local" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "contract_local_#{System.unique_integer([:positive])}")

      original = Application.get_env(:cyfr, :base_path)
      Application.put_env(:cyfr, :base_path, base)

      on_exit(fn ->
        File.rm_rf(base)

        if original,
          do: Application.put_env(:cyfr, :base_path, original),
          else: Application.delete_env(:cyfr, :base_path)
      end)

      ctx = Sanctum.TestContext.local()
      :ok = Local.put(ctx, ["guest", "a.txt"], "a")
      :ok = Local.put(ctx, ["guest", "b.txt"], "b")
      :ok = Local.put(ctx, ["guest", "sub", "c.txt"], "c")

      {:ok, ctx: ctx}
    end

    test("put/2 then get/2 round-trips the bytes", %{ctx: ctx},
      do: contract_put_get_roundtrip(Local, ctx)
    )

    test("append/3 creates, then concatenates", %{ctx: ctx},
      do: contract_append_roundtrip(Local, ctx)
    )

    test("tells a directory from a file", %{ctx: ctx}, do: contract_dir_vs_file(Local, ctx, []))

    test("a path that is a file is not an empty directory", %{ctx: ctx},
      do: contract_file_is_not_a_directory(Local, ctx)
    )

    test("a path with nothing under it lists empty", %{ctx: ctx},
      do: contract_empty_listing(Local, ctx)
    )

    test("get/2 on a directory is :not_found", %{ctx: ctx},
      do: contract_get_directory_is_not_found(Local, ctx)
    )

    test("serve_to_conn/4 on a missing path or directory is :not_found", %{ctx: ctx},
      do: contract_serve_missing_and_directory_not_found(Local, ctx)
    )

    test("exists?/2 answers files, not directories", %{ctx: ctx},
      do: contract_exists_files_only(Local, ctx)
    )

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{ctx: ctx} do
      contract_delete(Local, ctx)
      refute Local.exists?(ctx, ["guest", "a.txt"])
    end

    test "delete_tree/2 removes an object at the tree's own path", %{ctx: ctx} do
      contract_delete_tree_object_at_path(Local, ctx)
      refute Local.exists?(ctx, ["guest", "a.txt"])
    end

    test("delete_tree/2 on a missing tree is :ok", %{ctx: ctx},
      do: contract_delete_tree_missing_is_ok(Local, ctx)
    )

    test("list_recursive/2 returns every leaf as full segments", %{ctx: ctx},
      do: contract_list_recursive(Local, ctx)
    )

    test("usage/2 counts files and bytes, nothing else", %{ctx: ctx},
      do: contract_usage(Local, ctx)
    )

    test("read_subtree/2 returns relative pairs", %{ctx: ctx},
      do: contract_read_subtree(Local, ctx)
    )

    test("an over-long segment is refused before any I/O", %{ctx: ctx},
      do: contract_overlong_segment_refused(Local, ctx)
    )

    test("seed writes refuse with the one message", %{ctx: ctx},
      do: contract_seed_writes_refused(Local, ctx)
    )

    test("traversal segments refuse before any I/O", %{ctx: ctx},
      do: contract_traversal_refused(Local, ctx)
    )
  end

  # ---------------------------------------------------------------------------
  # Overlay decorator — contract-transparent for non-overlaid paths
  # ---------------------------------------------------------------------------

  describe "Arca.Overlay (decorator)" do
    # The overlay implements the same behaviour it wraps; on paths outside
    # its overlaid roots (the whole `guest/` scope this suite uses) it must
    # be a pure pass-through — every contract answer identical to the inner
    # adapter's. The union semantics themselves are pinned in overlay_test.
    setup do
      base =
        Path.join(System.tmp_dir!(), "contract_overlay_#{System.unique_integer([:positive])}")

      seed = Path.join(base, "seed")
      File.mkdir_p!(seed)

      original_base = Application.get_env(:cyfr, :base_path)
      original_seed = Application.get_env(:cyfr, :seed_path)
      Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
      Application.put_env(:cyfr, :seed_path, seed)

      on_exit(fn ->
        File.rm_rf(base)

        if original_base,
          do: Application.put_env(:cyfr, :base_path, original_base),
          else: Application.delete_env(:cyfr, :base_path)

        if original_seed,
          do: Application.put_env(:cyfr, :seed_path, original_seed),
          else: Application.delete_env(:cyfr, :seed_path)
      end)

      ctx = Sanctum.TestContext.local()
      :ok = Arca.Overlay.put(ctx, ["guest", "a.txt"], "a")
      :ok = Arca.Overlay.put(ctx, ["guest", "b.txt"], "b")
      :ok = Arca.Overlay.put(ctx, ["guest", "sub", "c.txt"], "c")

      {:ok, ctx: ctx}
    end

    test("put/2 then get/2 round-trips the bytes", %{ctx: ctx},
      do: contract_put_get_roundtrip(Arca.Overlay, ctx)
    )

    test("append/3 creates then extends", %{ctx: ctx},
      do: contract_append_roundtrip(Arca.Overlay, ctx)
    )

    test("tells a directory from a file", %{ctx: ctx},
      do: contract_dir_vs_file(Arca.Overlay, ctx, [])
    )

    test("a file is not a directory", %{ctx: ctx},
      do: contract_file_is_not_a_directory(Arca.Overlay, ctx)
    )

    test("an empty prefix lists empty", %{ctx: ctx},
      do: contract_empty_listing(Arca.Overlay, ctx)
    )

    test("get/2 on a directory is :not_found", %{ctx: ctx},
      do: contract_get_directory_is_not_found(Arca.Overlay, ctx)
    )

    test("serve_to_conn/4 on a missing path or directory is :not_found", %{ctx: ctx},
      do: contract_serve_missing_and_directory_not_found(Arca.Overlay, ctx)
    )

    test("exists?/2 answers for files only", %{ctx: ctx},
      do: contract_exists_files_only(Arca.Overlay, ctx)
    )

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{ctx: ctx} do
      contract_delete(Arca.Overlay, ctx)
    end

    test("delete_tree/2 removes an object at the tree's own path", %{ctx: ctx},
      do: contract_delete_tree_object_at_path(Arca.Overlay, ctx)
    )

    test("delete_tree/2 on a missing tree is :ok", %{ctx: ctx},
      do: contract_delete_tree_missing_is_ok(Arca.Overlay, ctx)
    )

    test("list_recursive/2 answers full segment lists", %{ctx: ctx},
      do: contract_list_recursive(Arca.Overlay, ctx)
    )

    test("usage/2 counts files and bytes, nothing else", %{ctx: ctx},
      do: contract_usage(Arca.Overlay, ctx)
    )

    test("read_subtree/2 returns relative pairs", %{ctx: ctx},
      do: contract_read_subtree(Arca.Overlay, ctx)
    )

    test("an over-long segment is refused before any I/O", %{ctx: ctx},
      do: contract_overlong_segment_refused(Arca.Overlay, ctx)
    )

    test("seed writes refuse with the one message", %{ctx: ctx},
      do: contract_seed_writes_refused(Arca.Overlay, ctx)
    )

    test("traversal segments refuse before any I/O", %{ctx: ctx},
      do: contract_traversal_refused(Arca.Overlay, ctx)
    )
  end

  # ---------------------------------------------------------------------------
  # S3
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.S3" do
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

      listing = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>athanors/ath_test/guest/a.txt</Key><Size>1</Size></Contents>
        <Contents><Key>athanors/ath_test/guest/b.txt</Key><Size>1</Size></Contents>
        <Contents><Key>athanors/ath_test/guest/sub/c.txt</Key><Size>1</Size></Contents>
        <Contents><Key>athanors/ath_test/guest/marker/</Key><Size>0</Size></Contents>
      </ListBucketResult>
      """

      empty = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>
      """

      # A stateful object store, so the write-side contract cases (put→get,
      # append) can actually round-trip. Listings stay the static fixture —
      # the tree-shape cases assert against it, never against writes.
      store =
        start_supervised!(
          {Agent,
           fn ->
             %{
               "/test-bucket/athanors/ath_test/guest/a.txt" => "a",
               "/test-bucket/athanors/ath_test/guest/b.txt" => "b",
               "/test-bucket/athanors/ath_test/guest/sub/c.txt" => "c"
             }
           end}
        )

      Req.Test.stub(:s3, fn conn ->
        prefix = Plug.Conn.fetch_query_params(conn).query_params["prefix"]

        cond do
          # A listing under the tree prefix.
          conn.method == "GET" and prefix == "athanors/ath_test/guest/" ->
            Plug.Conn.send_resp(conn, 200, listing)

          # Any other listing is empty.
          conn.method == "GET" and is_binary(prefix) ->
            Plug.Conn.send_resp(conn, 200, empty)

          conn.method == "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            Agent.update(store, &Map.put(&1, conn.request_path, body))
            Plug.Conn.send_resp(conn, 200, "")

          # The stored objects answer GETs and HEADs; nothing else exists.
          conn.method in ["GET", "HEAD"] ->
            case Agent.get(store, &Map.get(&1, conn.request_path)) do
              nil -> Plug.Conn.send_resp(conn, 404, "")
              body -> Plug.Conn.send_resp(conn, 200, body)
            end

          # Deletes succeed for any key — real S3 does not 404 a DELETE.
          conn.method == "DELETE" ->
            Agent.update(store, &Map.delete(&1, conn.request_path))
            Plug.Conn.send_resp(conn, 204, "")

          true ->
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

    test("put/2 then get/2 round-trips the bytes", %{ctx: ctx},
      do: contract_put_get_roundtrip(S3, ctx)
    )

    test("append/3 creates, then concatenates", %{ctx: ctx},
      do: contract_append_roundtrip(S3, ctx)
    )

    test("tells a directory from a file", %{ctx: ctx},
      do: contract_dir_vs_file(S3, ctx, [{"marker", :dir}])
    )

    test("a path that is a file is not an empty directory", %{ctx: ctx},
      do: contract_file_is_not_a_directory(S3, ctx)
    )

    test("a path with nothing under it lists empty", %{ctx: ctx},
      do: contract_empty_listing(S3, ctx)
    )

    test("get/2 on a directory is :not_found", %{ctx: ctx},
      do: contract_get_directory_is_not_found(S3, ctx)
    )

    test("serve_to_conn/4 on a missing path or directory is :not_found", %{ctx: ctx},
      do: contract_serve_missing_and_directory_not_found(S3, ctx)
    )

    test("exists?/2 answers files, not directories", %{ctx: ctx},
      do: contract_exists_files_only(S3, ctx)
    )

    test("delete/2: a missing file is :not_found, a deleted file is gone", %{ctx: ctx},
      do: contract_delete(S3, ctx)
    )

    test("delete_tree/2 removes an object at the tree's own path", %{ctx: ctx},
      do: contract_delete_tree_object_at_path(S3, ctx)
    )

    test("delete_tree/2 on a missing tree is :ok", %{ctx: ctx},
      do: contract_delete_tree_missing_is_ok(S3, ctx)
    )

    test("list_recursive/2 returns every leaf as full segments", %{ctx: ctx},
      do: contract_list_recursive(S3, ctx)
    )

    test("usage/2 counts files and bytes, nothing else", %{ctx: ctx}, do: contract_usage(S3, ctx))

    test("read_subtree/2 returns relative pairs", %{ctx: ctx}, do: contract_read_subtree(S3, ctx))

    test "a zero-byte directory marker reads as a directory, not a file", %{ctx: ctx} do
      # Some consoles write an empty object at `foo/` to make a folder appear.
      # It lists as a directory, and the walks (list_recursive/usage/
      # read_subtree, asserted above) never report it as content.
      {:ok, entries} = S3.list_typed(ctx, ["guest"])
      assert Enum.filter(entries, &(elem(&1, 0) == "marker")) == [{"marker", :dir}]
    end

    test("an over-long segment is refused before any I/O", %{ctx: ctx},
      do: contract_overlong_segment_refused(S3, ctx)
    )

    test("seed writes refuse with the one message", %{ctx: ctx},
      do: contract_seed_writes_refused(S3, ctx)
    )

    test("traversal segments refuse before any I/O", %{ctx: ctx},
      do: contract_traversal_refused(S3, ctx)
    )
  end
end
