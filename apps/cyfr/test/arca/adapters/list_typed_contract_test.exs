# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.ListTypedContractTest do
  @moduledoc """
  One contract, asserted against both adapters.

  `list_typed/2` exists so a caller can tell a directory from a file without
  knowing which adapter is configured — the guest storage tool's trailing-`/`
  convention rides on it. Each adapter has its own suite; this file is the
  place the two are held to the *same* answers, which is what the callback is
  for. The adapters disagreed here before it existed: a path that is a file
  answered `{:error, :enotdir}` on one and `{:ok, []}` on the other, and no
  test covered it. `exists?/2`, `delete/2` and `delete_tree/2` joined for the
  same reason — directory probes, missing-key deletes and an object at a
  tree's own path all had adapter-specific answers once.
  """

  use ExUnit.Case, async: false

  alias Arca.Adapters.Local
  alias Arca.Adapters.S3

  # ---------------------------------------------------------------------------
  # Local
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.Local" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "list_typed_local_#{System.unique_integer([:positive])}")

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

    test "tells a directory from a file", %{ctx: ctx} do
      assert {:ok, entries} = Local.list_typed(ctx, ["guest"])
      assert Enum.sort(entries) == [{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}]
    end

    test "a path that is a file is not an empty directory", %{ctx: ctx} do
      assert {:error, :enotdir} = Local.list_typed(ctx, ["guest", "a.txt"])
    end

    test "a path with nothing under it lists empty", %{ctx: ctx} do
      assert {:ok, []} = Local.list_typed(ctx, ["guest", "nothing-here"])
    end

    test "list/2 returns the same names", %{ctx: ctx} do
      {:ok, entries} = Local.list_typed(ctx, ["guest"])
      {:ok, names} = Local.list(ctx, ["guest"])
      assert Enum.sort(names) == entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    test "exists?/2 answers files, not directories", %{ctx: ctx} do
      assert Local.exists?(ctx, ["guest", "a.txt"])
      refute Local.exists?(ctx, ["guest"])
      refute Local.exists?(ctx, ["guest", "missing.txt"])
    end

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{ctx: ctx} do
      assert {:error, :not_found} = Local.delete(ctx, ["guest", "missing.txt"])
      assert :ok = Local.delete(ctx, ["guest", "a.txt"])
      refute Local.exists?(ctx, ["guest", "a.txt"])
    end

    test "delete_tree/2 removes an object at the tree's own path", %{ctx: ctx} do
      assert :ok = Local.delete_tree(ctx, ["guest", "a.txt"])
      refute Local.exists?(ctx, ["guest", "a.txt"])
    end
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
        <Contents><Key>athanors/ath_test/guest/a.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/guest/b.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/guest/sub/c.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/guest/marker/</Key></Contents>
      </ListBucketResult>
      """

      empty = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>
      """

      Req.Test.stub(:s3, fn conn ->
        prefix = Plug.Conn.fetch_query_params(conn).query_params["prefix"]

        cond do
          # A listing under the tree prefix.
          conn.method == "GET" and prefix == "athanors/ath_test/guest/" ->
            Plug.Conn.send_resp(conn, 200, listing)

          # Any other listing is empty.
          conn.method == "GET" and is_binary(prefix) ->
            Plug.Conn.send_resp(conn, 200, empty)

          # `a.txt` is a real object; nothing else is.
          conn.method == "HEAD" and
              conn.request_path == "/test-bucket/athanors/ath_test/guest/a.txt" ->
            Plug.Conn.send_resp(conn, 200, "")

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

    test "tells a directory from a file", %{ctx: ctx} do
      assert {:ok, entries} = S3.list_typed(ctx, ["guest"])

      assert Enum.sort(entries) == [
               {"a.txt", :file},
               {"b.txt", :file},
               {"marker", :dir},
               {"sub", :dir}
             ]
    end

    test "a path that is a file is not an empty directory", %{ctx: ctx} do
      assert {:error, :enotdir} = S3.list_typed(ctx, ["guest", "a.txt"])
    end

    test "a path with nothing under it lists empty", %{ctx: ctx} do
      assert {:ok, []} = S3.list_typed(ctx, ["guest", "nothing-here"])
    end

    test "list/2 returns the same names", %{ctx: ctx} do
      {:ok, entries} = S3.list_typed(ctx, ["guest"])
      {:ok, names} = S3.list(ctx, ["guest"])
      assert Enum.sort(names) == entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    test "exists?/2 answers files, not directories", %{ctx: ctx} do
      assert S3.exists?(ctx, ["guest", "a.txt"])
      refute S3.exists?(ctx, ["guest"])
      refute S3.exists?(ctx, ["guest", "missing.txt"])
    end

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{ctx: ctx} do
      assert {:error, :not_found} = S3.delete(ctx, ["guest", "missing.txt"])
      assert :ok = S3.delete(ctx, ["guest", "a.txt"])
    end

    test "delete_tree/2 removes an object at the tree's own path", %{ctx: ctx} do
      assert :ok = S3.delete_tree(ctx, ["guest", "a.txt"])
    end

    test "a zero-byte directory marker reads as a directory, not a file", %{ctx: ctx} do
      # Some consoles write an empty object at `foo/` to make a folder appear.
      # The key has nothing after the trailing slash, so a naive basename read
      # calls it a file; the local adapter would call the same thing a
      # directory. `marker/` is that object in the fixture.
      {:ok, entries} = S3.list_typed(ctx, ["guest"])
      assert Enum.filter(entries, &(elem(&1, 0) == "marker")) == [{"marker", :dir}]
    end
  end
end
