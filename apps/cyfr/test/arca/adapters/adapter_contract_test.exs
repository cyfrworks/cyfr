# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.ContractTest do
  @moduledoc """
  One contract, asserted against both adapters — with one shared assertion
  body per case, so an invariant cannot be added to one adapter's suite and
  forgotten in the other's.

  Checks shared Local and S3 behavior for object reads, existence, deletion,
  typed listings and path validation. Names-only listings derive from
  `list_typed/2` in the Arca facade.

  The shared fixture tree under `data/`: `a.txt` = "a", `b.txt` = "b",
  `sub/c.txt` = "c" (and, on S3, a `marker/` directory-marker object).

  The conditional writes and the prefix listing (`put_if_none_match/3`,
  `put_if_match/4`, `list_prefix/2`) have their contract rows here too.
  They run against `Arca.Storage.TestDouble` today; the Local and S3 rows
  are skipped, with the reason, until the adapters export the callbacks.
  """

  use ExUnit.Case, async: false

  alias Arca.Adapters.Local
  alias Arca.Adapters.S3

  defmodule Double do
    @moduledoc false
    use Arca.Storage.TestDouble
  end

  # An adapter that exports none of the optional callbacks: what the
  # facade must refuse conditional writes for.
  defmodule WithoutConditionals do
    @moduledoc false
    @behaviour Arca.Storage

    defdelegate get(ctx, path), to: Local
    defdelegate put(ctx, path, content), to: Local
    defdelegate append(ctx, path, content), to: Local
    defdelegate delete(ctx, path), to: Local
    defdelegate list_typed(ctx, path), to: Local
    defdelegate exists?(ctx, path), to: Local
    defdelegate delete_tree(ctx, path), to: Local
    defdelegate list_recursive(ctx, path), to: Local
    defdelegate usage(ctx, path), to: Local
    defdelegate ensure_dir(ctx, path), to: Local
    defdelegate serve_to_conn(conn, ctx, path, opts), to: Local
  end

  @conditional_pending "the adapter does not export the conditional callbacks yet; " <>
                         "un-skip when it implements put_if_none_match/3, put_if_match/4 " <>
                         "and list_prefix/2"

  # ---------------------------------------------------------------------------
  # The shared contract — one body per case, called from both describes.
  # ---------------------------------------------------------------------------

  defp contract_put_get_roundtrip(adapter, ctx) do
    assert :ok = adapter.put(ctx, ["data", "rt.txt"], "round-trip")
    assert {:ok, "round-trip"} = adapter.get(ctx, ["data", "rt.txt"])
  end

  # Both adapters create on first append and concatenate subsequent data.
  # Their separate suites cover size limits and concurrency semantics.
  defp contract_append_roundtrip(adapter, ctx) do
    assert :ok = adapter.append(ctx, ["data", "log.jsonl"], "one\n")
    assert :ok = adapter.append(ctx, ["data", "log.jsonl"], "two\n")
    assert {:ok, "one\ntwo\n"} = adapter.get(ctx, ["data", "log.jsonl"])
  end

  defp contract_dir_vs_file(adapter, ctx, extra_dirs) do
    assert {:ok, entries} = adapter.list_typed(ctx, ["data"])

    expected =
      Enum.sort([{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}] ++ extra_dirs)

    assert Enum.sort(entries) == expected
  end

  defp contract_file_is_not_a_directory(adapter, ctx) do
    assert {:error, :enotdir} = adapter.list_typed(ctx, ["data", "a.txt"])
  end

  # Both adapters return :not_found when reading a directory as an object.
  defp contract_get_directory_is_not_found(adapter, ctx) do
    assert {:error, :not_found} = adapter.get(ctx, ["data", "sub"])
  end

  defp contract_serve_missing_and_directory_not_found(adapter, ctx) do
    conn = Plug.Test.conn(:get, "/")
    assert {:error, :not_found} = adapter.serve_to_conn(conn, ctx, ["data", "missing.txt"], [])
    assert {:error, :not_found} = adapter.serve_to_conn(conn, ctx, ["data", "sub"], [])
  end

  defp contract_empty_listing(adapter, ctx) do
    assert {:ok, []} = adapter.list_typed(ctx, ["data", "nothing-here"])
  end

  defp contract_exists_files_only(adapter, ctx) do
    assert adapter.exists?(ctx, ["data", "a.txt"])
    refute adapter.exists?(ctx, ["data"])
    refute adapter.exists?(ctx, ["data", "missing.txt"])
  end

  defp contract_delete(adapter, ctx) do
    assert {:error, :not_found} = adapter.delete(ctx, ["data", "missing.txt"])
    assert :ok = adapter.delete(ctx, ["data", "a.txt"])
  end

  defp contract_delete_tree_object_at_path(adapter, ctx) do
    assert :ok = adapter.delete_tree(ctx, ["data", "a.txt"])
  end

  # Tree deletion is idempotent — "make this subtree not exist" already
  # holds for a missing tree. `:not_found` is delete/2's answer for a
  # missing single object, never delete_tree/2's.
  defp contract_delete_tree_missing_is_ok(adapter, ctx) do
    assert :ok = adapter.delete_tree(ctx, ["data", "nothing-here"])
  end

  defp contract_list_recursive(adapter, ctx) do
    assert {:ok, leaves} = adapter.list_recursive(ctx, ["data"])

    assert Enum.sort(leaves) == [
             ["data", "a.txt"],
             ["data", "b.txt"],
             ["data", "sub", "c.txt"]
           ]
  end

  defp contract_usage(adapter, ctx) do
    # Three files, one byte each — a directory marker is not a file and a
    # directory has no bytes, on either adapter.
    assert {:ok, %{files: 3, bytes: 3}} = adapter.usage(ctx, ["data"])
  end

  # read_subtree is no adapter callback — one shared algorithm over
  # list_recursive + get (`Arca.Storage.read_subtree_via/4`). Run here per
  # adapter anyway: the shared code must answer identically over each
  # adapter's listing and read semantics, file-path contract included.
  defp contract_read_subtree(adapter, ctx) do
    assert {:ok, pairs} = Arca.Storage.read_subtree_via(adapter, ctx, ["data"])

    assert Enum.sort(pairs) == [
             {["a.txt"], "a"},
             {["b.txt"], "b"},
             {["sub", "c.txt"], "c"}
           ]

    # A file is not a subtree; a missing prefix is honestly empty.
    assert {:error, :enotdir} = Arca.Storage.read_subtree_via(adapter, ctx, ["data", "a.txt"])
    assert {:ok, []} = Arca.Storage.read_subtree_via(adapter, ctx, ["data", "nope"])
  end

  # Both adapters reject overlong names during validation, before I/O.
  defp contract_overlong_segment_refused(adapter, ctx) do
    long = String.duplicate("a", 300)

    assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
      adapter.put(ctx, ["data", long], "x")
    end

    assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
      adapter.get(ctx, ["data", long])
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
      adapter.get(ctx, ["data", "..", "escape.txt"])
    end

    assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
      adapter.put(ctx, ["data", "..", "escape.txt"], "x")
    end
  end

  # A create lands once: the second create of a key answers `:exists` and
  # leaves the first bytes, whether the key was made by a create or was
  # already in the tree. Iodata is accepted.
  defp contract_put_if_none_match_creates_once(adapter, ctx) do
    key = ["data", "registry", "unit-1"]

    assert {:ok, precondition} = adapter.put_if_none_match(ctx, key, ["fir", "st"])
    assert {:ok, "first"} = adapter.get(ctx, key)

    assert {:error, :exists} = adapter.put_if_none_match(ctx, key, "second")
    assert {:ok, "first"} = adapter.get(ctx, key)

    assert {:error, :exists} = adapter.put_if_none_match(ctx, ["data", "a.txt"], "x")
    assert {:ok, "a"} = adapter.get(ctx, ["data", "a.txt"])

    # The precondition is what a conditional replace of the same bytes
    # needs, so a create's answer is usable as-is.
    assert {:ok, _next} = adapter.put_if_match(ctx, key, "third", precondition)
    assert {:ok, "third"} = adapter.get(ctx, key)
  end

  # A conditional replace moves the precondition: the one it answered
  # stands, the one it replaced is stale and writes nothing.
  defp contract_put_if_match_moves_the_precondition(adapter, ctx) do
    key = ["data", "registry", "unit-2"]

    assert {:ok, first} = adapter.put_if_none_match(ctx, key, "v1")
    assert {:ok, second} = adapter.put_if_match(ctx, key, "v2", first)
    assert second != first
    assert {:ok, "v2"} = adapter.get(ctx, key)

    assert {:error, :precondition_failed} = adapter.put_if_match(ctx, key, "v3", first)
    assert {:ok, "v2"} = adapter.get(ctx, key)

    assert {:ok, _third} = adapter.put_if_match(ctx, key, ["v", "3"], second)
    assert {:ok, "v3"} = adapter.get(ctx, key)
  end

  # There is nothing to replace at a missing key: no write, whatever the
  # precondition claims.
  defp contract_put_if_match_missing_key(adapter, ctx) do
    key = ["data", "registry", "absent"]

    assert {:error, :missing} = adapter.put_if_match(ctx, key, "x", "any-precondition")
    refute adapter.exists?(ctx, key)
  end

  # A prefix listing answers every key below the prefix, nested ones
  # included, as full segments; an empty prefix is honestly empty; a
  # prefix that is one object answers that object.
  defp contract_list_prefix(adapter, ctx) do
    assert {:ok, []} = adapter.list_prefix(ctx, ["data", "nothing-here"])

    assert {:ok, keys} = adapter.list_prefix(ctx, ["data"])

    assert Enum.sort(keys) == [
             ["data", "a.txt"],
             ["data", "b.txt"],
             ["data", "sub", "c.txt"]
           ]

    assert {:ok, [["data", "sub", "c.txt"]]} = adapter.list_prefix(ctx, ["data", "sub"])
    assert {:ok, [["data", "a.txt"]]} = adapter.list_prefix(ctx, ["data", "a.txt"])
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
      :ok = Local.put(ctx, ["data", "a.txt"], "a")
      :ok = Local.put(ctx, ["data", "b.txt"], "b")
      :ok = Local.put(ctx, ["data", "sub", "c.txt"], "c")

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
      refute Local.exists?(ctx, ["data", "a.txt"])
    end

    test "delete_tree/2 removes an object at the tree's own path", %{ctx: ctx} do
      contract_delete_tree_object_at_path(Local, ctx)
      refute Local.exists?(ctx, ["data", "a.txt"])
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

    @tag skip: @conditional_pending
    test("put_if_none_match/3 creates a key once", %{ctx: ctx},
      do: contract_put_if_none_match_creates_once(Local, ctx)
    )

    @tag skip: @conditional_pending
    test("put_if_match/4 moves the precondition and refuses a stale one", %{ctx: ctx},
      do: contract_put_if_match_moves_the_precondition(Local, ctx)
    )

    @tag skip: @conditional_pending
    test("put_if_match/4 on a missing key writes nothing", %{ctx: ctx},
      do: contract_put_if_match_missing_key(Local, ctx)
    )

    @tag skip: @conditional_pending
    test("list_prefix/2 answers every key below a prefix", %{ctx: ctx},
      do: contract_list_prefix(Local, ctx)
    )
  end

  # ---------------------------------------------------------------------------
  # The test double — the conditional contract, until Local and S3 carry it
  # ---------------------------------------------------------------------------

  describe "Arca.Storage.TestDouble" do
    setup do
      {:ok, ctx: local_tree!("contract_double")}
    end

    test("put_if_none_match/3 creates a key once", %{ctx: ctx},
      do: contract_put_if_none_match_creates_once(Double, ctx)
    )

    test("put_if_match/4 moves the precondition and refuses a stale one", %{ctx: ctx},
      do: contract_put_if_match_moves_the_precondition(Double, ctx)
    )

    test("put_if_match/4 on a missing key writes nothing", %{ctx: ctx},
      do: contract_put_if_match_missing_key(Double, ctx)
    )

    test("list_prefix/2 answers every key below a prefix", %{ctx: ctx},
      do: contract_list_prefix(Double, ctx)
    )

    test "racing creates of one key land exactly one", %{ctx: ctx} do
      key = ["data", "registry", "raced"]

      answers =
        1..8
        |> Task.async_stream(fn n -> Double.put_if_none_match(ctx, key, "writer-#{n}") end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.count(answers, &match?({:ok, _}, &1)) == 1
      assert Enum.count(answers, &(&1 == {:error, :exists})) == 7
      assert {:ok, "writer-" <> _} = Double.get(ctx, key)
    end
  end

  # ---------------------------------------------------------------------------
  # The facade's dispatch — the configured adapter, or a refusal
  # ---------------------------------------------------------------------------

  describe "Arca.Storage conditional dispatch" do
    setup do
      ctx = local_tree!("contract_dispatch")
      original = Application.get_env(:cyfr, :storage_adapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      {:ok, ctx: ctx}
    end

    test "reaches the configured adapter's callbacks", %{ctx: ctx} do
      Application.put_env(:cyfr, :storage_adapter, Double)
      key = ["data", "registry", "dispatched"]

      assert {:ok, precondition} = Arca.Storage.put_if_none_match(ctx, key, "one")
      assert {:error, :exists} = Arca.Storage.put_if_none_match(ctx, key, "two")
      assert {:ok, _next} = Arca.Storage.put_if_match(ctx, key, "two", precondition)

      assert {:error, :precondition_failed} =
               Arca.Storage.put_if_match(ctx, key, "x", precondition)

      assert {:ok, [^key]} = Arca.Storage.list_prefix(ctx, key)
    end

    test "refuses, writing nothing, when the adapter exports no conditional callbacks",
         %{ctx: ctx} do
      Application.put_env(:cyfr, :storage_adapter, WithoutConditionals)
      key = ["data", "registry", "refused"]

      assert {:error, :unsupported} = Arca.Storage.put_if_none_match(ctx, key, "one")
      assert {:error, :unsupported} = Arca.Storage.put_if_match(ctx, ["data", "a.txt"], "x", "p")
      assert {:error, :unsupported} = Arca.Storage.list_prefix(ctx, ["data"])

      refute WithoutConditionals.exists?(ctx, key)
      assert {:ok, "a"} = WithoutConditionals.get(ctx, ["data", "a.txt"])
    end
  end

  # A fresh Local tree under tmp holding the shared fixture, torn down with
  # the test; the context to read it with.
  defp local_tree!(tag) do
    base = Path.join(System.tmp_dir!(), "#{tag}_#{System.unique_integer([:positive])}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)

    on_exit(fn ->
      File.rm_rf(base)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Local.put(ctx, ["data", "a.txt"], "a")
    :ok = Local.put(ctx, ["data", "b.txt"], "b")
    :ok = Local.put(ctx, ["data", "sub", "c.txt"], "c")
    ctx
  end

  # ---------------------------------------------------------------------------
  # Overlay decorator — contract-transparent for non-overlaid paths
  # ---------------------------------------------------------------------------

  describe "Arca.Overlay (decorator)" do
    # The overlay implements the same behaviour it wraps; on paths outside
    # its overlaid roots (the whole `data/` scope this suite uses) it must
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
      :ok = Arca.Overlay.put(ctx, ["data", "a.txt"], "a")
      :ok = Arca.Overlay.put(ctx, ["data", "b.txt"], "b")
      :ok = Arca.Overlay.put(ctx, ["data", "sub", "c.txt"], "c")

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
        <Contents><Key>athanors/ath_test/data/a.txt</Key><Size>1</Size></Contents>
        <Contents><Key>athanors/ath_test/data/b.txt</Key><Size>1</Size></Contents>
        <Contents><Key>athanors/ath_test/data/sub/c.txt</Key><Size>1</Size></Contents>
        <Contents><Key>athanors/ath_test/data/marker/</Key><Size>0</Size></Contents>
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
               "/test-bucket/athanors/ath_test/data/a.txt" => "a",
               "/test-bucket/athanors/ath_test/data/b.txt" => "b",
               "/test-bucket/athanors/ath_test/data/sub/c.txt" => "c"
             }
           end}
        )

      Req.Test.stub(:s3, fn conn ->
        prefix = Plug.Conn.fetch_query_params(conn).query_params["prefix"]

        cond do
          # A listing under the tree prefix.
          conn.method == "GET" and prefix == "athanors/ath_test/data/" ->
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
      {:ok, entries} = S3.list_typed(ctx, ["data"])
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

    @tag skip: @conditional_pending
    test("put_if_none_match/3 creates a key once", %{ctx: ctx},
      do: contract_put_if_none_match_creates_once(S3, ctx)
    )

    @tag skip: @conditional_pending
    test("put_if_match/4 moves the precondition and refuses a stale one", %{ctx: ctx},
      do: contract_put_if_match_moves_the_precondition(S3, ctx)
    )

    @tag skip: @conditional_pending
    test("put_if_match/4 on a missing key writes nothing", %{ctx: ctx},
      do: contract_put_if_match_missing_key(S3, ctx)
    )

    @tag skip: @conditional_pending
    test("list_prefix/2 answers every key below a prefix", %{ctx: ctx},
      do: contract_list_prefix(S3, ctx)
    )
  end
end
