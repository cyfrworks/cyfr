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
  They run against Local, S3 and `Arca.Storage.TestDouble`; the S3 stub
  store honours `If-None-Match: *` and `If-Match` as a real one does.
  """

  use ExUnit.Case, async: false

  alias Arca.Adapters.Local
  alias Arca.Adapters.S3

  defmodule Double do
    @moduledoc false
    use Arca.Storage.TestDouble
  end

  # ---------------------------------------------------------------------------
  # The shared contract — one body per case, called from both describes.
  # ---------------------------------------------------------------------------

  defp contract_put_get_roundtrip(adapter, actor) do
    assert :ok = adapter.put(actor, ["data", "rt.txt"], "round-trip")
    assert {:ok, "round-trip"} = adapter.get(actor, ["data", "rt.txt"])
  end

  # Both adapters create on first append and concatenate subsequent data.
  # Their separate suites cover size limits and concurrency semantics.
  defp contract_append_roundtrip(adapter, actor) do
    assert :ok = adapter.append(actor, ["data", "log.jsonl"], "one\n")
    assert :ok = adapter.append(actor, ["data", "log.jsonl"], "two\n")
    assert {:ok, "one\ntwo\n"} = adapter.get(actor, ["data", "log.jsonl"])
  end

  defp contract_dir_vs_file(adapter, actor, extra_dirs) do
    assert {:ok, entries} = adapter.list_typed(actor, ["data"])

    expected =
      Enum.sort([{"a.txt", :file}, {"b.txt", :file}, {"sub", :dir}] ++ extra_dirs)

    assert Enum.sort(entries) == expected
  end

  defp contract_file_is_not_a_directory(adapter, actor) do
    assert {:error, :enotdir} = adapter.list_typed(actor, ["data", "a.txt"])
  end

  # Both adapters return :not_found when reading a directory as an object.
  defp contract_get_directory_is_not_found(adapter, actor) do
    assert {:error, :not_found} = adapter.get(actor, ["data", "sub"])
  end

  defp contract_serve_missing_and_directory_not_found(adapter, actor) do
    conn = Plug.Test.conn(:get, "/")
    assert {:error, :not_found} = adapter.serve_to_conn(conn, actor, ["data", "missing.txt"], [])
    assert {:error, :not_found} = adapter.serve_to_conn(conn, actor, ["data", "sub"], [])
  end

  defp contract_empty_listing(adapter, actor) do
    assert {:ok, []} = adapter.list_typed(actor, ["data", "nothing-here"])
  end

  defp contract_exists_files_only(adapter, actor) do
    assert adapter.exists?(actor, ["data", "a.txt"])
    refute adapter.exists?(actor, ["data"])
    refute adapter.exists?(actor, ["data", "missing.txt"])
  end

  defp contract_delete(adapter, actor) do
    assert {:error, :not_found} = adapter.delete(actor, ["data", "missing.txt"])
    assert :ok = adapter.delete(actor, ["data", "a.txt"])
  end

  defp contract_delete_tree_object_at_path(adapter, actor) do
    assert :ok = adapter.delete_tree(actor, ["data", "a.txt"])
  end

  # Tree deletion is idempotent — "make this subtree not exist" already
  # holds for a missing tree. `:not_found` is delete/2's answer for a
  # missing single object, never delete_tree/2's.
  defp contract_delete_tree_missing_is_ok(adapter, actor) do
    assert :ok = adapter.delete_tree(actor, ["data", "nothing-here"])
  end

  defp contract_list_recursive(adapter, actor) do
    assert {:ok, leaves} = adapter.list_recursive(actor, ["data"])

    assert Enum.sort(leaves) == [
             ["data", "a.txt"],
             ["data", "b.txt"],
             ["data", "sub", "c.txt"]
           ]
  end

  defp contract_usage(adapter, actor) do
    # Three files, one byte each — a directory marker is not a file and a
    # directory has no bytes, on either adapter.
    assert {:ok, %{files: 3, bytes: 3}} = adapter.usage(actor, ["data"])
  end

  # read_subtree is no adapter callback — one shared algorithm over
  # list_recursive + get (`Arca.Storage.read_subtree_via/4`). Run here per
  # adapter anyway: the shared code must answer identically over each
  # adapter's listing and read semantics, file-path contract included.
  defp contract_read_subtree(adapter, actor) do
    assert {:ok, pairs} = Arca.Storage.read_subtree_via(adapter, actor, ["data"])

    assert Enum.sort(pairs) == [
             {["a.txt"], "a"},
             {["b.txt"], "b"},
             {["sub", "c.txt"], "c"}
           ]

    # A file is not a subtree; a missing prefix is honestly empty.
    assert {:error, :enotdir} = Arca.Storage.read_subtree_via(adapter, actor, ["data", "a.txt"])
    assert {:ok, []} = Arca.Storage.read_subtree_via(adapter, actor, ["data", "nope"])
  end

  # Both adapters reject overlong names during validation, before I/O.
  defp contract_overlong_segment_refused(adapter, actor) do
    long = String.duplicate("a", 300)

    assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
      adapter.put(actor, ["data", long], "x")
    end

    assert_raise ArgumentError, ~r/segment longer than 240 bytes/, fn ->
      adapter.get(actor, ["data", long])
    end
  end

  # Seed media is read-only at every adapter, with ONE message — the two
  # adapters once refused with different mechanisms and different words
  # (`Arca.Storage.refuse_seed_write!/1` is now the single spelling).
  defp contract_seed_writes_refused(adapter, actor) do
    for call <- [
          fn -> adapter.put(actor, ["seed", "components", "x.txt"], "x") end,
          fn -> adapter.append(actor, ["seed", "components", "x.txt"], "x") end,
          fn -> adapter.delete(actor, ["seed", "components", "x.txt"]) end,
          fn -> adapter.delete_tree(actor, ["seed", "components"]) end
        ] do
      assert_raise ArgumentError, ~r/seed media is read-only/, call
    end
  end

  # Traversal segments refuse identically at validation, before any I/O —
  # the same denylist on every adapter.
  defp contract_traversal_refused(adapter, actor) do
    assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
      adapter.get(actor, ["data", "..", "escape.txt"])
    end

    assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
      adapter.put(actor, ["data", "..", "escape.txt"], "x")
    end
  end

  # A create lands once: the second create of a key answers `:exists` and
  # leaves the first bytes, whether the key was made by a create or was
  # already in the tree. Iodata is accepted.
  defp contract_put_if_none_match_creates_once(adapter, actor) do
    key = ["data", "registry", "unit-1"]

    assert {:ok, precondition} = adapter.put_if_none_match(actor, key, ["fir", "st"])
    assert {:ok, "first"} = adapter.get(actor, key)

    assert {:error, :exists} = adapter.put_if_none_match(actor, key, "second")
    assert {:ok, "first"} = adapter.get(actor, key)

    assert {:error, :exists} = adapter.put_if_none_match(actor, ["data", "a.txt"], "x")
    assert {:ok, "a"} = adapter.get(actor, ["data", "a.txt"])

    # The precondition is what a conditional replace of the same bytes
    # needs, so a create's answer is usable as-is.
    assert {:ok, _next} = adapter.put_if_match(actor, key, "third", precondition)
    assert {:ok, "third"} = adapter.get(actor, key)
  end

  # A conditional replace moves the precondition: the one it answered
  # stands, the one it replaced is stale and writes nothing.
  defp contract_put_if_match_moves_the_precondition(adapter, actor) do
    key = ["data", "registry", "unit-2"]

    assert {:ok, first} = adapter.put_if_none_match(actor, key, "v1")
    assert {:ok, second} = adapter.put_if_match(actor, key, "v2", first)
    assert second != first
    assert {:ok, "v2"} = adapter.get(actor, key)

    assert {:error, :precondition_failed} = adapter.put_if_match(actor, key, "v3", first)
    assert {:ok, "v2"} = adapter.get(actor, key)

    assert {:ok, _third} = adapter.put_if_match(actor, key, ["v", "3"], second)
    assert {:ok, "v3"} = adapter.get(actor, key)
  end

  # There is nothing to replace at a missing key: no write, whatever the
  # precondition claims.
  defp contract_put_if_match_missing_key(adapter, actor) do
    key = ["data", "registry", "absent"]

    assert {:error, :missing} = adapter.put_if_match(actor, key, "x", "any-precondition")
    refute adapter.exists?(actor, key)
  end

  # A prefix listing answers every key below the prefix, nested ones
  # included, as full segments; an empty prefix is honestly empty; a
  # prefix that is one object answers that object.
  defp contract_list_prefix(adapter, actor) do
    assert {:ok, []} = adapter.list_prefix(actor, ["data", "nothing-here"])

    assert {:ok, keys} = adapter.list_prefix(actor, ["data"])

    assert Enum.sort(keys) == [
             ["data", "a.txt"],
             ["data", "b.txt"],
             ["data", "sub", "c.txt"]
           ]

    assert {:ok, [["data", "sub", "c.txt"]]} = adapter.list_prefix(actor, ["data", "sub"])
    assert {:ok, [["data", "a.txt"]]} = adapter.list_prefix(actor, ["data", "a.txt"])
  end

  # ---------------------------------------------------------------------------
  # Local
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.Local" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "contract_local_#{System.unique_integer([:positive])}")

      original = Application.get_env(:arca, :base_path)
      Application.put_env(:arca, :base_path, base)

      on_exit(fn ->
        File.rm_rf(base)

        if original,
          do: Application.put_env(:arca, :base_path, original),
          else: Application.delete_env(:arca, :base_path)
      end)

      actor = Arca.Test.Actor.local()
      :ok = Local.put(actor, ["data", "a.txt"], "a")
      :ok = Local.put(actor, ["data", "b.txt"], "b")
      :ok = Local.put(actor, ["data", "sub", "c.txt"], "c")

      {:ok, actor: actor}
    end

    test("put/2 then get/2 round-trips the bytes", %{actor: actor},
      do: contract_put_get_roundtrip(Local, actor)
    )

    test("append/3 creates, then concatenates", %{actor: actor},
      do: contract_append_roundtrip(Local, actor)
    )

    test("tells a directory from a file", %{actor: actor},
      do: contract_dir_vs_file(Local, actor, [])
    )

    test("a path that is a file is not an empty directory", %{actor: actor},
      do: contract_file_is_not_a_directory(Local, actor)
    )

    test("a path with nothing under it lists empty", %{actor: actor},
      do: contract_empty_listing(Local, actor)
    )

    test("get/2 on a directory is :not_found", %{actor: actor},
      do: contract_get_directory_is_not_found(Local, actor)
    )

    test("serve_to_conn/4 on a missing path or directory is :not_found", %{actor: actor},
      do: contract_serve_missing_and_directory_not_found(Local, actor)
    )

    test("exists?/2 answers files, not directories", %{actor: actor},
      do: contract_exists_files_only(Local, actor)
    )

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{actor: actor} do
      contract_delete(Local, actor)
      refute Local.exists?(actor, ["data", "a.txt"])
    end

    test "delete_tree/2 removes an object at the tree's own path", %{actor: actor} do
      contract_delete_tree_object_at_path(Local, actor)
      refute Local.exists?(actor, ["data", "a.txt"])
    end

    test("delete_tree/2 on a missing tree is :ok", %{actor: actor},
      do: contract_delete_tree_missing_is_ok(Local, actor)
    )

    test("list_recursive/2 returns every leaf as full segments", %{actor: actor},
      do: contract_list_recursive(Local, actor)
    )

    test("usage/2 counts files and bytes, nothing else", %{actor: actor},
      do: contract_usage(Local, actor)
    )

    test("read_subtree/2 returns relative pairs", %{actor: actor},
      do: contract_read_subtree(Local, actor)
    )

    test("an over-long segment is refused before any I/O", %{actor: actor},
      do: contract_overlong_segment_refused(Local, actor)
    )

    test("seed writes refuse with the one message", %{actor: actor},
      do: contract_seed_writes_refused(Local, actor)
    )

    test("traversal segments refuse before any I/O", %{actor: actor},
      do: contract_traversal_refused(Local, actor)
    )

    test("put_if_none_match/3 creates a key once", %{actor: actor},
      do: contract_put_if_none_match_creates_once(Local, actor)
    )

    test("put_if_match/4 moves the precondition and refuses a stale one", %{actor: actor},
      do: contract_put_if_match_moves_the_precondition(Local, actor)
    )

    test("put_if_match/4 on a missing key writes nothing", %{actor: actor},
      do: contract_put_if_match_missing_key(Local, actor)
    )

    test("list_prefix/2 answers every key below a prefix", %{actor: actor},
      do: contract_list_prefix(Local, actor)
    )
  end

  # ---------------------------------------------------------------------------
  # The test double — the conditional contract every adapter carries
  # ---------------------------------------------------------------------------

  describe "Arca.Storage.TestDouble" do
    setup do
      {:ok, actor: local_tree!("contract_double")}
    end

    test("put_if_none_match/3 creates a key once", %{actor: actor},
      do: contract_put_if_none_match_creates_once(Double, actor)
    )

    test("put_if_match/4 moves the precondition and refuses a stale one", %{actor: actor},
      do: contract_put_if_match_moves_the_precondition(Double, actor)
    )

    test("put_if_match/4 on a missing key writes nothing", %{actor: actor},
      do: contract_put_if_match_missing_key(Double, actor)
    )

    test("list_prefix/2 answers every key below a prefix", %{actor: actor},
      do: contract_list_prefix(Double, actor)
    )

    test "racing creates of one key land exactly one", %{actor: actor} do
      key = ["data", "registry", "raced"]

      answers =
        1..8
        |> Task.async_stream(fn n -> Double.put_if_none_match(actor, key, "writer-#{n}") end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.count(answers, &match?({:ok, _}, &1)) == 1
      assert Enum.count(answers, &(&1 == {:error, :exists})) == 7
      assert {:ok, "writer-" <> _} = Double.get(actor, key)
    end
  end

  # ---------------------------------------------------------------------------
  # The facade's dispatch — the configured adapter, or a refusal
  # ---------------------------------------------------------------------------

  describe "Arca.Storage conditional dispatch" do
    setup do
      actor = local_tree!("contract_dispatch")
      original = Application.get_env(:arca, :storage_adapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arca, :storage_adapter, original),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      {:ok, actor: actor}
    end

    test "reaches the configured adapter's callbacks", %{actor: actor} do
      Application.put_env(:arca, :storage_adapter, Double)
      key = ["data", "registry", "dispatched"]

      assert {:ok, precondition} =
               Arca.Storage.put_if_none_match(actor, key, "one")

      assert {:error, :exists} =
               Arca.Storage.put_if_none_match(actor, key, "two")

      assert {:ok, next} =
               Arca.Storage.put_if_match(actor, key, "two", precondition)

      assert {:error, :precondition_failed} =
               Arca.Storage.put_if_match(actor, key, "x", precondition)

      assert {:ok, [^key]} = Arca.Storage.list_prefix(actor, key)
      assert {:ok, "two", ^next} = Arca.Storage.get_for_update(actor, key)
    end
  end

  # A fresh Local tree under tmp holding the shared fixture, torn down with
  # the test; the actor to read it with.
  defp local_tree!(tag) do
    base = Path.join(System.tmp_dir!(), "#{tag}_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      File.rm_rf(base)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    actor = Arca.Test.Actor.local()
    :ok = Local.put(actor, ["data", "a.txt"], "a")
    :ok = Local.put(actor, ["data", "b.txt"], "b")
    :ok = Local.put(actor, ["data", "sub", "c.txt"], "c")
    actor
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

      original_base = Application.get_env(:arca, :base_path)
      original_seed = Application.get_env(:arca, :seed_path)
      Application.put_env(:arca, :base_path, Path.join(base, "data"))
      Application.put_env(:arca, :seed_path, seed)

      on_exit(fn ->
        File.rm_rf(base)

        if original_base,
          do: Application.put_env(:arca, :base_path, original_base),
          else: Application.delete_env(:arca, :base_path)

        if original_seed,
          do: Application.put_env(:arca, :seed_path, original_seed),
          else: Application.delete_env(:arca, :seed_path)
      end)

      actor = Arca.Test.Actor.local()
      :ok = Arca.Overlay.put(actor, ["data", "a.txt"], "a")
      :ok = Arca.Overlay.put(actor, ["data", "b.txt"], "b")
      :ok = Arca.Overlay.put(actor, ["data", "sub", "c.txt"], "c")

      {:ok, actor: actor}
    end

    test("put/2 then get/2 round-trips the bytes", %{actor: actor},
      do: contract_put_get_roundtrip(Arca.Overlay, actor)
    )

    test("append/3 creates then extends", %{actor: actor},
      do: contract_append_roundtrip(Arca.Overlay, actor)
    )

    test("tells a directory from a file", %{actor: actor},
      do: contract_dir_vs_file(Arca.Overlay, actor, [])
    )

    test("a file is not a directory", %{actor: actor},
      do: contract_file_is_not_a_directory(Arca.Overlay, actor)
    )

    test("an empty prefix lists empty", %{actor: actor},
      do: contract_empty_listing(Arca.Overlay, actor)
    )

    test("get/2 on a directory is :not_found", %{actor: actor},
      do: contract_get_directory_is_not_found(Arca.Overlay, actor)
    )

    test("serve_to_conn/4 on a missing path or directory is :not_found", %{actor: actor},
      do: contract_serve_missing_and_directory_not_found(Arca.Overlay, actor)
    )

    test("exists?/2 answers for files only", %{actor: actor},
      do: contract_exists_files_only(Arca.Overlay, actor)
    )

    test "delete/2: a missing file is :not_found, a deleted file is gone", %{actor: actor} do
      contract_delete(Arca.Overlay, actor)
    end

    test("delete_tree/2 removes an object at the tree's own path", %{actor: actor},
      do: contract_delete_tree_object_at_path(Arca.Overlay, actor)
    )

    test("delete_tree/2 on a missing tree is :ok", %{actor: actor},
      do: contract_delete_tree_missing_is_ok(Arca.Overlay, actor)
    )

    test("list_recursive/2 answers full segment lists", %{actor: actor},
      do: contract_list_recursive(Arca.Overlay, actor)
    )

    test("usage/2 counts files and bytes, nothing else", %{actor: actor},
      do: contract_usage(Arca.Overlay, actor)
    )

    test("read_subtree/2 returns relative pairs", %{actor: actor},
      do: contract_read_subtree(Arca.Overlay, actor)
    )

    test("an over-long segment is refused before any I/O", %{actor: actor},
      do: contract_overlong_segment_refused(Arca.Overlay, actor)
    )

    test("seed writes refuse with the one message", %{actor: actor},
      do: contract_seed_writes_refused(Arca.Overlay, actor)
    )

    test("traversal segments refuse before any I/O", %{actor: actor},
      do: contract_traversal_refused(Arca.Overlay, actor)
    )
  end

  # ---------------------------------------------------------------------------
  # S3
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.S3" do
    setup do
      Application.put_env(:arca, :s3,
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

      sub_listing = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>athanors/ath_test/data/sub/c.txt</Key><Size>1</Size></Contents>
      </ListBucketResult>
      """

      # An object's ETag as a store answers it: the quoted MD5 of its bytes.
      etag = fn body -> ~s("#{Base.encode16(:crypto.hash(:md5, body), case: :lower)}") end

      # The store's side of a conditional PUT, the check and the write one
      # step: `If-None-Match: *` refuses an occupied key with 412, `If-Match`
      # a changed object with 412 and a missing key with 404.
      conditional_put = fn conn, body ->
        if_none_match = Plug.Conn.get_req_header(conn, "if-none-match")
        if_match = Plug.Conn.get_req_header(conn, "if-match")

        Agent.get_and_update(store, fn objects ->
          current = Map.get(objects, conn.request_path)

          cond do
            if_none_match == ["*"] and current != nil -> {412, objects}
            if_match != [] and current == nil -> {404, objects}
            if_match != [] and if_match != [etag.(current)] -> {412, objects}
            true -> {200, Map.put(objects, conn.request_path, body)}
          end
        end)
      end

      Req.Test.stub(:s3, fn conn ->
        prefix = Plug.Conn.fetch_query_params(conn).query_params["prefix"]

        cond do
          # A listing under the tree prefix, and under its one subdirectory.
          conn.method == "GET" and prefix == "athanors/ath_test/data/" ->
            Plug.Conn.send_resp(conn, 200, listing)

          conn.method == "GET" and prefix == "athanors/ath_test/data/sub/" ->
            Plug.Conn.send_resp(conn, 200, sub_listing)

          # Any other listing is empty.
          conn.method == "GET" and is_binary(prefix) ->
            Plug.Conn.send_resp(conn, 200, empty)

          conn.method == "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            case conditional_put.(conn, body) do
              200 ->
                conn
                |> Plug.Conn.put_resp_header("etag", etag.(body))
                |> Plug.Conn.send_resp(200, "")

              refused ->
                Plug.Conn.send_resp(conn, refused, "")
            end

          # The stored objects answer GETs and HEADs; nothing else exists.
          conn.method in ["GET", "HEAD"] ->
            case Agent.get(store, &Map.get(&1, conn.request_path)) do
              nil ->
                Plug.Conn.send_resp(conn, 404, "")

              body ->
                conn
                |> Plug.Conn.put_resp_header("etag", etag.(body))
                |> Plug.Conn.send_resp(200, body)
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
        Application.delete_env(:arca, :s3)
      end)

      {:ok, actor: Arca.Test.Actor.local()}
    end

    test("put/2 then get/2 round-trips the bytes", %{actor: actor},
      do: contract_put_get_roundtrip(S3, actor)
    )

    test("append/3 creates, then concatenates", %{actor: actor},
      do: contract_append_roundtrip(S3, actor)
    )

    test("tells a directory from a file", %{actor: actor},
      do: contract_dir_vs_file(S3, actor, [{"marker", :dir}])
    )

    test("a path that is a file is not an empty directory", %{actor: actor},
      do: contract_file_is_not_a_directory(S3, actor)
    )

    test("a path with nothing under it lists empty", %{actor: actor},
      do: contract_empty_listing(S3, actor)
    )

    test("get/2 on a directory is :not_found", %{actor: actor},
      do: contract_get_directory_is_not_found(S3, actor)
    )

    test("serve_to_conn/4 on a missing path or directory is :not_found", %{actor: actor},
      do: contract_serve_missing_and_directory_not_found(S3, actor)
    )

    test("exists?/2 answers files, not directories", %{actor: actor},
      do: contract_exists_files_only(S3, actor)
    )

    test("delete/2: a missing file is :not_found, a deleted file is gone", %{actor: actor},
      do: contract_delete(S3, actor)
    )

    test("delete_tree/2 removes an object at the tree's own path", %{actor: actor},
      do: contract_delete_tree_object_at_path(S3, actor)
    )

    test("delete_tree/2 on a missing tree is :ok", %{actor: actor},
      do: contract_delete_tree_missing_is_ok(S3, actor)
    )

    test("list_recursive/2 returns every leaf as full segments", %{actor: actor},
      do: contract_list_recursive(S3, actor)
    )

    test("usage/2 counts files and bytes, nothing else", %{actor: actor},
      do: contract_usage(S3, actor)
    )

    test("read_subtree/2 returns relative pairs", %{actor: actor},
      do: contract_read_subtree(S3, actor)
    )

    test "a zero-byte directory marker reads as a directory, not a file", %{actor: actor} do
      # Some consoles write an empty object at `foo/` to make a folder appear.
      # It lists as a directory, and the walks (list_recursive/usage/
      # read_subtree, asserted above) never report it as content.
      {:ok, entries} = S3.list_typed(actor, ["data"])
      assert Enum.filter(entries, &(elem(&1, 0) == "marker")) == [{"marker", :dir}]
    end

    test("an over-long segment is refused before any I/O", %{actor: actor},
      do: contract_overlong_segment_refused(S3, actor)
    )

    test("seed writes refuse with the one message", %{actor: actor},
      do: contract_seed_writes_refused(S3, actor)
    )

    test("traversal segments refuse before any I/O", %{actor: actor},
      do: contract_traversal_refused(S3, actor)
    )

    test("put_if_none_match/3 creates a key once", %{actor: actor},
      do: contract_put_if_none_match_creates_once(S3, actor)
    )

    test("put_if_match/4 moves the precondition and refuses a stale one", %{actor: actor},
      do: contract_put_if_match_moves_the_precondition(S3, actor)
    )

    test("put_if_match/4 on a missing key writes nothing", %{actor: actor},
      do: contract_put_if_match_missing_key(S3, actor)
    )

    test("list_prefix/2 answers every key below a prefix", %{actor: actor},
      do: contract_list_prefix(S3, actor)
    )
  end
end
