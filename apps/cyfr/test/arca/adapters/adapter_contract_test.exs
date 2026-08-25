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

  defp contract_dir_vs_file(adapter, ctx, extra_dirs) do
    assert {:ok, entries} = adapter.list_typed(ctx, ["guest"])

    expected =
      Enum.sort([{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}] ++ extra_dirs)

    assert Enum.sort(entries) == expected
  end

  defp contract_file_is_not_a_directory(adapter, ctx) do
    assert {:error, :enotdir} = adapter.list_typed(ctx, ["guest", "a.txt"])
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

  defp contract_read_subtree(adapter, ctx) do
    assert {:ok, pairs} = adapter.read_subtree(ctx, ["guest"])

    assert Enum.sort(pairs) == [
             {["a.txt"], "a"},
             {["b.txt"], "b"},
             {["sub", "c.txt"], "c"}
           ]
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

    test "tells a directory from a file", %{ctx: ctx},
      do: contract_dir_vs_file(Local, ctx, [])

    test "a path that is a file is not an empty directory", %{ctx: ctx},
      do: contract_file_is_not_a_directory(Local, ctx)

    test "a path with nothing under it lists empty", %{ctx: ctx},
      do: contract_empty_listing(Local, ctx)

    test "exists?/2 answers files, not directories", %{ctx: ctx},
      do: contract_exists_files_only(Local, ctx)

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{ctx: ctx} do
      contract_delete(Local, ctx)
      refute Local.exists?(ctx, ["guest", "a.txt"])
    end

    test "delete_tree/2 removes an object at the tree's own path", %{ctx: ctx} do
      contract_delete_tree_object_at_path(Local, ctx)
      refute Local.exists?(ctx, ["guest", "a.txt"])
    end

    test "list_recursive/2 returns every leaf as full segments", %{ctx: ctx},
      do: contract_list_recursive(Local, ctx)

    test "usage/2 counts files and bytes, nothing else", %{ctx: ctx},
      do: contract_usage(Local, ctx)

    test "read_subtree/2 returns relative pairs", %{ctx: ctx},
      do: contract_read_subtree(Local, ctx)
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

      objects = %{
        "/test-bucket/athanors/ath_test/guest/a.txt" => "a",
        "/test-bucket/athanors/ath_test/guest/b.txt" => "b",
        "/test-bucket/athanors/ath_test/guest/sub/c.txt" => "c"
      }

      Req.Test.stub(:s3, fn conn ->
        prefix = Plug.Conn.fetch_query_params(conn).query_params["prefix"]

        cond do
          # A listing under the tree prefix.
          conn.method == "GET" and prefix == "athanors/ath_test/guest/" ->
            Plug.Conn.send_resp(conn, 200, listing)

          # Any other listing is empty.
          conn.method == "GET" and is_binary(prefix) ->
            Plug.Conn.send_resp(conn, 200, empty)

          # The fixture objects answer GETs and HEADs; nothing else exists.
          conn.method in ["GET", "HEAD"] and is_map_key(objects, conn.request_path) ->
            Plug.Conn.send_resp(conn, 200, Map.fetch!(objects, conn.request_path))

          # Deletes succeed for any key — real S3 does not 404 a DELETE.
          conn.method == "DELETE" ->
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

    test "tells a directory from a file", %{ctx: ctx},
      do: contract_dir_vs_file(S3, ctx, [{"marker", :dir}])

    test "a path that is a file is not an empty directory", %{ctx: ctx},
      do: contract_file_is_not_a_directory(S3, ctx)

    test "a path with nothing under it lists empty", %{ctx: ctx},
      do: contract_empty_listing(S3, ctx)

    test "exists?/2 answers files, not directories", %{ctx: ctx},
      do: contract_exists_files_only(S3, ctx)

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{ctx: ctx},
      do: contract_delete(S3, ctx)

    test "delete_tree/2 removes an object at the tree's own path", %{ctx: ctx},
      do: contract_delete_tree_object_at_path(S3, ctx)

    test "list_recursive/2 returns every leaf as full segments", %{ctx: ctx},
      do: contract_list_recursive(S3, ctx)

    test "usage/2 counts files and bytes, nothing else", %{ctx: ctx},
      do: contract_usage(S3, ctx)

    test "read_subtree/2 returns relative pairs", %{ctx: ctx},
      do: contract_read_subtree(S3, ctx)

    test "a zero-byte directory marker reads as a directory, not a file", %{ctx: ctx} do
      # Some consoles write an empty object at `foo/` to make a folder appear.
      # It lists as a directory, and the walks (list_recursive/usage/
      # read_subtree, asserted above) never report it as content.
      {:ok, entries} = S3.list_typed(ctx, ["guest"])
      assert Enum.filter(entries, &(elem(&1, 0) == "marker")) == [{"marker", :dir}]
    end
  end
end
