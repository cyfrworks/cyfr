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
  test covered it.
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
      :ok = Local.put(ctx, ["tree", "a.txt"], "a")
      :ok = Local.put(ctx, ["tree", "b.txt"], "b")
      :ok = Local.put(ctx, ["tree", "sub", "c.txt"], "c")

      {:ok, ctx: ctx}
    end

    test "tells a directory from a file", %{ctx: ctx} do
      assert {:ok, entries} = Local.list_typed(ctx, ["tree"])
      assert Enum.sort(entries) == [{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}]
    end

    test "a path that is a file is not an empty directory", %{ctx: ctx} do
      assert {:error, :enotdir} = Local.list_typed(ctx, ["tree", "a.txt"])
    end

    test "a path with nothing under it lists empty", %{ctx: ctx} do
      assert {:ok, []} = Local.list_typed(ctx, ["nothing-here"])
    end

    test "list/2 returns the same names", %{ctx: ctx} do
      {:ok, entries} = Local.list_typed(ctx, ["tree"])
      {:ok, names} = Local.list(ctx, ["tree"])
      assert Enum.sort(names) == entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
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
        <Contents><Key>athanors/ath_test/data/tree/a.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/data/tree/b.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/data/tree/sub/c.txt</Key></Contents>
        <Contents><Key>athanors/ath_test/data/tree/marker/</Key></Contents>
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
          conn.method == "GET" and prefix == "athanors/ath_test/data/tree/" ->
            Plug.Conn.send_resp(conn, 200, listing)

          # Any other listing is empty.
          conn.method == "GET" and is_binary(prefix) ->
            Plug.Conn.send_resp(conn, 200, empty)

          # `a.txt` is a real object; nothing else is.
          conn.method == "HEAD" and
              conn.request_path == "/test-bucket/athanors/ath_test/data/tree/a.txt" ->
            Plug.Conn.send_resp(conn, 200, "")

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
      assert {:ok, entries} = S3.list_typed(ctx, ["tree"])

      assert Enum.sort(entries) == [
               {"a.txt", :file},
               {"b.txt", :file},
               {"marker", :dir},
               {"sub", :dir}
             ]
    end

    test "a path that is a file is not an empty directory", %{ctx: ctx} do
      assert {:error, :enotdir} = S3.list_typed(ctx, ["tree", "a.txt"])
    end

    test "a path with nothing under it lists empty", %{ctx: ctx} do
      assert {:ok, []} = S3.list_typed(ctx, ["nothing-here"])
    end

    test "list/2 returns the same names", %{ctx: ctx} do
      {:ok, entries} = S3.list_typed(ctx, ["tree"])
      {:ok, names} = S3.list(ctx, ["tree"])
      assert Enum.sort(names) == entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    test "a zero-byte directory marker reads as a directory, not a file", %{ctx: ctx} do
      # Some consoles write an empty object at `foo/` to make a folder appear.
      # The key has nothing after the trailing slash, so a naive basename read
      # calls it a file; the local adapter would call the same thing a
      # directory. `marker/` is that object in the fixture.
      {:ok, entries} = S3.list_typed(ctx, ["tree"])
      assert Enum.filter(entries, &(elem(&1, 0) == "marker")) == [{"marker", :dir}]
    end
  end
end
