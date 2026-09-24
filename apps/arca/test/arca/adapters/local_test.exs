# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.LocalTest do
  use ExUnit.Case, async: false

  alias Arca.Adapters.Local

  @test_base_path System.tmp_dir!() |> Path.join("arca_test_#{:rand.uniform(100_000)}")

  setup do
    # Use a unique temp directory for each test run
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, @test_base_path)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(@test_base_path)
    end)

    actor = Arca.Test.Actor.local()
    {:ok, actor: actor}
  end

  describe "put/3 and get/2" do
    test "writes and reads content", %{actor: actor} do
      content = "hello world"
      path = ["data", "file.txt"]

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "creates nested directories", %{actor: actor} do
      content = "nested content"
      path = ["data", "nested", "path", "file.txt"]

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "handles binary content", %{actor: actor} do
      content = <<0, 1, 2, 3, 255>>
      path = ["data", "data.bin"]

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end
  end

  describe "get/2 errors" do
    test "returns not_found for missing file", %{actor: actor} do
      assert {:error, :not_found} =
               Local.get(actor, ["data", "nonexistent", "file.txt"])
    end
  end

  describe "replace_tree/3" do
    @tree ["data", "site"]

    # What the tree's parent holds on disk, hidden names included.
    defp beside(actor), do: actor |> Local.build_path(["data"]) |> File.ls!() |> Enum.sort()

    test "lays a tree where none was, then replaces it whole", %{actor: actor} do
      assert :ok =
               Local.replace_tree(actor, @tree, [
                 {["index.html"], "one"},
                 {["a", "b.js"], "b"}
               ])

      assert {:ok, "one"} = Local.get(actor, @tree ++ ["index.html"])

      assert :ok =
               Local.replace_tree(actor, @tree, [
                 {["index.html"], fn -> {:ok, "two"} end}
               ])

      assert {:ok, [["data", "site", "index.html"]]} =
               Local.list_recursive(actor, @tree)

      assert {:ok, "two"} = Local.get(actor, @tree ++ ["index.html"])
      assert beside(actor) == ["site"]
    end

    test "a staging failure leaves the tree as it was and nothing staged", %{actor: actor} do
      :ok = Local.replace_tree(actor, @tree, [{["index.html"], "one"}])

      assert {:error, :enospc} =
               Local.replace_tree(actor, @tree, [
                 {["index.html"], "two"},
                 {["late.js"], fn -> {:error, :enospc} end}
               ])

      assert {:ok, [["data", "site", "index.html"]]} =
               Local.list_recursive(actor, @tree)

      assert {:ok, "one"} = Local.get(actor, @tree ++ ["index.html"])
      assert beside(actor) == ["site"]
    end

    test "the tree being staged is hidden from listings, walks and usage", %{actor: actor} do
      :ok = Local.replace_tree(actor, @tree, [{["index.html"], "one"}])
      test_pid = self()

      replacing =
        Task.async(fn ->
          Local.replace_tree(actor, @tree, [
            {["index.html"], "staged bytes"},
            {["late.js"],
             fn ->
               send(test_pid, {:staging, self()})

               receive do
                 :proceed -> {:ok, "late"}
               end
             end}
          ])
        end)

      assert_receive {:staging, replacer}, 5_000

      assert ["site", staged] = beside(actor)
      assert Arca.Storage.tmp_name?(staged)
      assert {:ok, [{"site", :dir}]} = Local.list_typed(actor, ["data"])

      assert {:ok, [["data", "site", "index.html"]]} =
               Local.list_recursive(actor, ["data"])

      assert {:ok, %{files: 1, bytes: 3}} = Local.usage(actor, ["data"])

      send(replacer, :proceed)
      assert :ok = Task.await(replacing, 30_000)
      assert {:ok, "late"} = Local.get(actor, @tree ++ ["late.js"])
      assert beside(actor) == ["site"]
    end

    test "every relative path is validated as a write's would be", %{actor: actor} do
      assert_raise ArgumentError, fn ->
        Local.replace_tree(actor, @tree, [{["..", "escape.txt"], "x"}])
      end

      refute File.exists?(Local.build_path(actor, ["data", "escape.txt"]))
    end
  end

  describe "replace_tree/3 crash recovery" do
    # A swap that died part-way, laid out as the adapter lays it: the
    # journal beside the trees under one number, recording the staged and
    # retired names. `present` is the trees the crash left on disk, each
    # with the bytes of its one file.
    defp crashed_swap!(actor, present) do
      live = Local.build_path(actor, @tree)
      names = %{live: live, staged: "#{live}.staged.tmp.7", retired: "#{live}.retired.tmp.7"}
      File.mkdir_p!(Path.dirname(live))

      for {tree, content} <- present do
        File.mkdir_p!(names[tree])
        File.write!(Path.join(names[tree], "index.html"), content)
      end

      journal = "#{live}.swap.tmp.7"

      File.write!(
        journal,
        Jason.encode!(%{
          "version" => 1,
          "live" => "site",
          "staged" => "site.staged.tmp.7",
          "retired" => "site.retired.tmp.7"
        })
      )

      Map.put(names, :journal, journal)
    end

    test "a crash before the first rename keeps the previous tree; the sweep clears the rest",
         %{actor: actor} do
      crashed_swap!(actor, live: "old", staged: "new")

      # The previous tree is what a reader sees, before and after the sweep.
      assert {:ok, "old"} = Local.get(actor, @tree ++ ["index.html"])
      assert {:ok, 1} = Local.sweep_stale_tmp(3600)
      assert {:ok, "old"} = Local.get(actor, @tree ++ ["index.html"])
      assert beside(actor) == ["site"]
    end

    test "a crash between the renames leaves both trees and the journal; the sweep installs the new one",
         %{actor: actor} do
      names = crashed_swap!(actor, staged: "new", retired: "old")

      # Both trees survive under their journalled names, whole.
      assert File.read!(Path.join(names.staged, "index.html")) == "new"
      assert File.read!(Path.join(names.retired, "index.html")) == "old"
      assert File.exists?(names.journal)

      # Everything here is stale by age, and the journal is still read
      # first: the trees it names are settled, never reclaimed as orphans.
      assert {:ok, 1} = Local.sweep_stale_tmp(-1)
      assert {:ok, "new"} = Local.get(actor, @tree ++ ["index.html"])
      assert beside(actor) == ["site"]
    end

    test "a crash between the renames with the staged tree lost puts the previous tree back",
         %{actor: actor} do
      crashed_swap!(actor, retired: "old")

      assert {:ok, 1} = Local.sweep_stale_tmp(3600)
      assert {:ok, "old"} = Local.get(actor, @tree ++ ["index.html"])
      assert beside(actor) == ["site"]
    end

    test "a crash after the second rename keeps the new tree; the sweep finishes the retirement",
         %{actor: actor} do
      names = crashed_swap!(actor, live: "new", retired: "old")

      assert {:ok, "new"} = Local.get(actor, @tree ++ ["index.html"])
      assert File.dir?(names.retired)

      # A fresh journal is settled whatever its age.
      assert {:ok, 1} = Local.sweep_stale_tmp(3600)
      assert {:ok, "new"} = Local.get(actor, @tree ++ ["index.html"])
      assert beside(actor) == ["site"]
    end

    test "a replacement after a crash lands, and the sweep clears the crashed swap's trees",
         %{actor: actor} do
      crashed_swap!(actor, staged: "new", retired: "old")

      assert :ok =
               Local.replace_tree(actor, @tree, [{["index.html"], "newest"}])

      assert {:ok, "newest"} = Local.get(actor, @tree ++ ["index.html"])

      assert {:ok, 1} = Local.sweep_stale_tmp(3600)
      assert {:ok, "newest"} = Local.get(actor, @tree ++ ["index.html"])
      assert beside(actor) == ["site"]
    end

    test "a journal that names anything but its own siblings directs no rename", %{actor: actor} do
      :ok = Local.put(actor, ["data", "keep", "a.txt"], "kept")
      names = crashed_swap!(actor, staged: "new")

      File.write!(
        names.journal,
        Jason.encode!(%{
          "version" => 1,
          "live" => "site",
          "staged" => "keep",
          "retired" => "site.retired.tmp.7"
        })
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 0} = Local.sweep_stale_tmp(3600)
        end)

      assert log =~ "unreadable swap journal"
      assert {:ok, "kept"} = Local.get(actor, ["data", "keep", "a.txt"])
      refute File.exists?(names.live)

      # Unreadable, it ages out with the orphans beside it.
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, 2} = Local.sweep_stale_tmp(-1)
      end)

      assert beside(actor) == ["keep"]
    end

    test "a journal that is an Erlang term, not the JSON record, directs no rename", %{
      actor: actor
    } do
      names = crashed_swap!(actor, staged: "new")

      File.write!(
        names.journal,
        :erlang.term_to_binary(%{
          version: 1,
          live: "site",
          staged: "site.staged.tmp.7",
          retired: "site.retired.tmp.7"
        })
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 0} = Local.sweep_stale_tmp(3600)
        end)

      assert log =~ "unreadable swap journal"
      refute File.exists?(names.live)
    end

    test "a successful replacement leaves no journal behind", %{actor: actor} do
      assert :ok =
               Local.replace_tree(actor, @tree, [{["index.html"], "one"}])

      assert :ok =
               Local.replace_tree(actor, @tree, [{["index.html"], "two"}])

      assert beside(actor) == ["site"]
      assert {:ok, 0} = Local.sweep_stale_tmp(-1)
    end
  end

  describe "conditional writes" do
    test "a create over an existing key is :exists and leaves the bytes", %{actor: actor} do
      key = ["data", "cond", "unit"]

      assert {:ok, precondition} =
               Local.put_if_none_match(actor, key, ["by", "tes"])

      assert precondition == Prima.Digest.sha256_hex("bytes")
      assert {:error, :exists} = Local.put_if_none_match(actor, key, "other")
      assert {:ok, "bytes"} = Local.get(actor, key)

      # A key a plain put made, and a directory, are as occupied.
      :ok = Local.put(actor, ["data", "cond", "plain"], "p")

      assert {:error, :exists} =
               Local.put_if_none_match(actor, ["data", "cond", "plain"], "x")

      assert {:error, :exists} =
               Local.put_if_none_match(actor, ["data", "cond"], "x")

      assert list_names(actor, ["data", "cond"]) == ["plain", "unit"]
    end

    test "a stale precondition is :precondition_failed and writes nothing", %{actor: actor} do
      key = ["data", "cond", "unit"]

      assert {:ok, first} = Local.put_if_none_match(actor, key, "v1")
      assert {:ok, second} = Local.put_if_match(actor, key, "v2", first)

      assert {:error, :precondition_failed} =
               Local.put_if_match(actor, key, "v3", first)

      assert {:error, :precondition_failed} =
               Local.put_if_match(actor, key, "v3", :not_a_digest)

      assert {:ok, "v2"} = Local.get(actor, key)

      # The precondition is the bytes' identity, whoever wrote them.
      :ok = Local.put(actor, key, "plain")

      assert {:error, :precondition_failed} =
               Local.put_if_match(actor, key, "v3", second)

      assert {:ok, _} =
               Local.put_if_match(
                 actor,
                 key,
                 "v3",
                 Prima.Digest.sha256_hex("plain")
               )

      assert list_names(actor, ["data", "cond"]) == ["unit"]
    end

    test "a missing key is :missing, a directory included, and nothing is created", %{
      actor: actor
    } do
      :ok = Local.put(actor, ["data", "cond", "dir", "child"], "c")

      assert {:error, :missing} =
               Local.put_if_match(
                 actor,
                 ["data", "cond", "absent"],
                 "x",
                 "p"
               )

      assert {:error, :missing} =
               Local.put_if_match(actor, ["data", "cond", "dir"], "x", "p")

      assert {:error, :missing} =
               Local.put_if_match(
                 actor,
                 ["data", "nowhere", "absent"],
                 "x",
                 "p"
               )

      assert list_names(actor, ["data"]) == ["cond"]
      assert list_names(actor, ["data", "cond"]) == ["dir"]
    end

    test "racing creates of one key land exactly one, whole", %{actor: actor} do
      key = ["data", "cond", "raced"]

      answers =
        1..16
        |> Task.async_stream(
          fn n ->
            Local.put_if_none_match(
              actor,
              key,
              String.duplicate("writer-#{n};", 5_000)
            )
          end,
          max_concurrency: 16,
          ordered: false
        )
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert [{:ok, winner}] = Enum.filter(answers, &match?({:ok, _}, &1))
      assert Enum.count(answers, &(&1 == {:error, :exists})) == 15

      assert {:ok, bytes} = Local.get(actor, key)
      assert Prima.Digest.sha256_hex(bytes) == winner
      assert list_names(actor, ["data", "cond"]) == ["raced"]
      assert actor |> Local.build_path(["data", "cond"]) |> File.ls!() == ["raced"]
    end

    test "racing replaces from one precondition land exactly one", %{actor: actor} do
      key = ["data", "cond", "raced"]
      {:ok, seen} = Local.put_if_none_match(actor, key, "v0")

      answers =
        1..16
        |> Task.async_stream(
          fn n -> Local.put_if_match(actor, key, "writer-#{n}", seen) end,
          max_concurrency: 16,
          ordered: false
        )
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert [{:ok, winner}] = Enum.filter(answers, &match?({:ok, _}, &1))
      assert Enum.count(answers, &(&1 == {:error, :precondition_failed})) == 15
      assert {:ok, "writer-" <> _ = bytes} = Local.get(actor, key)
      assert Prima.Digest.sha256_hex(bytes) == winner
    end

    test "a symlink is refused, and seed media stays read-only", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      outside = Path.join(System.tmp_dir!(), "arca_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      secret = Path.join(outside, "secret.txt")
      File.write!(secret, "secret")
      on_exit(fn -> File.rm_rf!(outside) end)

      tree_dir = Local.build_path(actor, ["data", "a.txt"]) |> Path.dirname()
      File.ln_s!(secret, Path.join(tree_dir, "link.txt"))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :symlink_denied} =
                 Local.put_if_match(
                   actor,
                   ["data", "link.txt"],
                   "injected",
                   Prima.Digest.sha256_hex("secret")
                 )
      end)

      assert {:error, :exists} =
               Local.put_if_none_match(
                 actor,
                 ["data", "link.txt"],
                 "injected"
               )

      assert File.read!(secret) == "secret"

      for call <- [
            fn ->
              Local.put_if_none_match(
                actor,
                ["seed", "components", "x.txt"],
                "x"
              )
            end,
            fn ->
              Local.put_if_match(
                actor,
                ["seed", "components", "x.txt"],
                "x",
                "p"
              )
            end
          ] do
        assert_raise ArgumentError, ~r/seed media is read-only/, call
      end
    end

    test "list_prefix/2 answers keys, never temp names or symlinks", %{actor: actor} do
      {:ok, _} = Local.put_if_none_match(actor, ["data", "reg", "u1"], "1")

      {:ok, _} =
        Local.put_if_none_match(actor, ["data", "reg", "deep", "u2"], "2")

      File.write!(
        Local.build_path(actor, ["data", "reg", "u1"]) <> ".tmp.5",
        "partial"
      )

      File.ln_s!(
        "/etc/hosts",
        Local.build_path(actor, ["data", "reg", "link"])
      )

      assert {:ok, keys} = Local.list_prefix(actor, ["data", "reg"])
      assert Enum.sort(keys) == [["data", "reg", "deep", "u2"], ["data", "reg", "u1"]]

      assert {:ok, [["data", "reg", "u1"]]} =
               Local.list_prefix(actor, ["data", "reg", "u1"])

      assert {:ok, []} = Local.list_prefix(actor, ["data", "reg", "link"])
      assert {:ok, []} = Local.list_prefix(actor, ["data", "reg", "absent"])
    end
  end

  describe "atomic-write hygiene" do
    test "in-flight temp names are invisible to listings, walks and usage", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      # A crashed put's orphan, next to its target.
      orphan = Local.build_path(actor, ["data", "a.txt"]) <> ".tmp.12345"
      File.write!(orphan, "partial")

      assert {:ok, [{"a.txt", :file}]} = Local.list_typed(actor, ["data"])

      assert {:ok, [["data", "a.txt"]]} =
               Local.list_recursive(actor, ["data"])

      assert {:ok, %{files: 1}} = Local.usage(actor, ["data"])
    end

    test "sweep_stale_tmp/1 removes only stale temp files", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")
      orphan = Local.build_path(actor, ["data", "a.txt"]) <> ".tmp.999"
      File.write!(orphan, "partial")

      # Too fresh to sweep.
      assert {:ok, 0} = Local.sweep_stale_tmp(3600)
      assert File.exists?(orphan)

      # A negative age makes everything stale.
      assert {:ok, 1} = Local.sweep_stale_tmp(-1)
      refute File.exists?(orphan)
      assert {:ok, "a"} = Local.get(actor, ["data", "a.txt"])
    end

    test "sweep_stale_tmp/1 reclaims an aged tmp-named directory subtree", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      # A tmp-named directory — the staged or retired tree a crashed
      # `replace_tree/3` leaves — hides its whole subtree from listings and
      # the usage walk.
      dir = Local.build_path(actor, ["data", "x.tmp.1"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "hidden.txt"), "hidden")

      # Fresh: kept — a writer may still be racing the fix window.
      assert {:ok, 0} = Local.sweep_stale_tmp(3600)
      assert File.dir?(dir)

      # Aged: the whole subtree is reclaimed as one entry.
      assert {:ok, 1} = Local.sweep_stale_tmp(-1)
      refute File.exists?(dir)
      assert {:ok, "a"} = Local.get(actor, ["data", "a.txt"])
    end

    test "the facade sweep asks an adapter that exports the callback, else answers zero" do
      # Local exports the optional callback — the facade dispatches to it.
      assert {:ok, n} = Arca.sweep_stale_tmp()
      assert is_integer(n)

      # An adapter without the export (an object store) is never asked.
      defmodule NoSweepAdapter do
        @moduledoc false
        defdelegate get(actor, path), to: Arca.Adapters.Local
        defdelegate put(actor, path, content), to: Arca.Adapters.Local
        defdelegate append(actor, path, content), to: Arca.Adapters.Local
        defdelegate delete(actor, path), to: Arca.Adapters.Local
        defdelegate list_typed(actor, path), to: Arca.Adapters.Local
        defdelegate exists?(actor, path), to: Arca.Adapters.Local
        defdelegate delete_tree(actor, path), to: Arca.Adapters.Local
        defdelegate list_recursive(actor, path), to: Arca.Adapters.Local
        defdelegate usage(actor, path), to: Arca.Adapters.Local
        defdelegate serve_to_conn(conn, actor, path, opts), to: Arca.Adapters.Local
      end

      original = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, NoSweepAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arca, :storage_adapter, original),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      assert {:ok, 0} = Arca.sweep_stale_tmp()
    end

    test "the sweep walks only Arca-owned trees, never the sidecar's or the DB's", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      # Stale orphans where Arca writes — swept.
      athanor_orphan = Local.build_path(actor, ["data", "a.txt"]) <> ".tmp.1"
      cache_orphan = Path.join([@test_base_path, "cache", "blob.tmp.2"])
      File.mkdir_p!(Path.dirname(cache_orphan))
      File.write!(athanor_orphan, "partial")
      File.write!(cache_orphan, "partial")

      # tmp-shaped files where OTHER programs live ("another program's
      # file" per Arca.Storage) — never touched, symlinks there never
      # reported.
      sidecar = Path.join(@test_base_path, "mcp-bridge")
      File.mkdir_p!(sidecar)
      sidecar_file = Path.join(sidecar, "state.tmp.3")
      File.write!(sidecar_file, "sidecar's own")
      root_file = Path.join(@test_base_path, "cyfr.db.tmp.4")
      File.write!(root_file, "not ours")

      outside = Path.join(System.tmp_dir!(), "arca_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.ln_s!(outside, Path.join(sidecar, "sidecar-link"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 2} = Local.sweep_stale_tmp(-1)
        end)

      refute File.exists?(athanor_orphan)
      refute File.exists?(cache_orphan)
      assert File.exists?(sidecar_file)
      assert File.exists?(root_file)
      refute log =~ "sidecar-link"
    end

    test "the sweep reports a planted symlink — the cheap detector for host tampering", %{
      actor: actor
    } do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      outside = Path.join(System.tmp_dir!(), "arca_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      tree_dir = Local.build_path(actor, ["data", "a.txt"]) |> Path.dirname()
      File.ln_s!(outside, Path.join(tree_dir, "planted"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Local.sweep_stale_tmp(3600)
        end)

      assert log =~ "symlink under storage root"
      assert log =~ "planted"
    end
  end

  describe "symlinks" do
    test "walks do not follow a symlink out of the tree", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      outside = Path.join(System.tmp_dir!(), "arca_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret")
      on_exit(fn -> File.rm_rf!(outside) end)

      tree_dir = Local.build_path(actor, ["data", "a.txt"]) |> Path.dirname()
      File.ln_s!(outside, Path.join(tree_dir, "link"))

      assert {:ok, [["data", "a.txt"]]} =
               Local.list_recursive(actor, ["data"])

      assert {:ok, %{files: 1, bytes: 1}} = Local.usage(actor, ["data"])
    end

    test "get/2 refuses a file symlink out of the tree", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      outside = Path.join(System.tmp_dir!(), "arca_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      secret = Path.join(outside, "secret.txt")
      File.write!(secret, "secret")
      on_exit(fn -> File.rm_rf!(outside) end)

      tree_dir = Local.build_path(actor, ["data", "a.txt"]) |> Path.dirname()
      File.ln_s!(secret, Path.join(tree_dir, "link.txt"))

      assert {:error, :symlink_denied} =
               Local.get(actor, ["data", "link.txt"])
    end

    test "append/3 refuses a file symlink and leaves the target untouched", %{actor: actor} do
      :ok = Local.put(actor, ["data", "a.txt"], "a")

      outside = Path.join(System.tmp_dir!(), "arca_outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      secret = Path.join(outside, "secret.txt")
      File.write!(secret, "secret")
      on_exit(fn -> File.rm_rf!(outside) end)

      tree_dir = Local.build_path(actor, ["data", "a.txt"]) |> Path.dirname()
      File.ln_s!(secret, Path.join(tree_dir, "link.txt"))

      assert {:error, :symlink_denied} =
               Local.append(actor, ["data", "link.txt"], "injected")

      assert File.read!(secret) == "secret"
    end
  end

  describe "seed writes" do
    test "every mutating callback refuses seed paths outright", %{actor: actor} do
      for call <- [
            fn -> Local.put(actor, ["seed", "components", "x.txt"], "x") end,
            fn ->
              Local.append(actor, ["seed", "components", "x.txt"], "x")
            end,
            fn -> Local.delete(actor, ["seed", "components", "x.txt"]) end,
            fn -> Local.delete_tree(actor, ["seed", "components"]) end
          ] do
        assert_raise ArgumentError, ~r/seed media is read-only/, call
      end
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{actor: actor} do
      path = ["data", "test.txt"]
      Local.put(actor, path, "content")

      assert Local.exists?(actor, path)
    end

    test "returns false for missing file", %{actor: actor} do
      refute Local.exists?(actor, ["data", "missing", "file.txt"])
    end
  end

  describe "delete/2" do
    test "removes existing file", %{actor: actor} do
      path = ["data", "me.txt"]
      Local.put(actor, path, "content")

      assert :ok == Local.delete(actor, path)
      refute Local.exists?(actor, path)
    end

    test "returns not_found for missing file", %{actor: actor} do
      assert {:error, :not_found} =
               Local.delete(actor, ["data", "missing.txt"])
    end
  end

  describe "listing names" do
    test "lists directory contents", %{actor: actor} do
      Local.put(actor, ["data", "dir", "a.txt"], "a")
      Local.put(actor, ["data", "dir", "b.txt"], "b")
      Local.put(actor, ["data", "dir", "c.txt"], "c")

      assert list_names(actor, ["data", "dir"]) == ["a.txt", "b.txt", "c.txt"]
    end

    test "returns empty list for missing directory", %{actor: actor} do
      assert list_names(actor, ["data", "nonexistent"]) == []
    end
  end

  describe "tenant-scoped paths" do
    test "stores files under {athanor_id} (namespace not in path)", %{actor: actor} do
      path = ["data", "isolation", "test.txt"]
      Local.put(actor, path, "content")

      # namespace is identity-only; the path is athanors/{athanor_id}/...
      expected_path =
        Path.join([
          @test_base_path,
          "athanors",
          actor.athanor_id,
          "data",
          "isolation",
          "test.txt"
        ])

      assert File.exists?(expected_path)
    end
  end

  describe "global paths" do
    test "cache is stored at root level", %{actor: actor} do
      path = ["cache", "oci", "sha256_abc123"]
      Local.put(actor, path, "wasm binary")

      expected_path = Path.join([@test_base_path, "cache", "oci", "sha256_abc123"])
      assert File.exists?(expected_path)
    end

    test "can read global paths", %{actor: actor} do
      path = ["cache", "oci", "sha256_test"]
      content = "cached content"
      Local.put(actor, path, content)

      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "can list global paths", %{actor: actor} do
      Local.put(actor, ["cache", "test_1.bin"], "1")
      Local.put(actor, ["cache", "test_2.bin"], "2")

      files = list_names(actor, ["cache"])
      assert "test_1.bin" in files
      assert "test_2.bin" in files
    end
  end

  describe "append/3" do
    test "appends content to file", %{actor: actor} do
      path = ["data", "2025-01-15.jsonl"]

      assert :ok == Local.append(actor, path, ~s|{"event":"login"}\n|)
      assert :ok == Local.append(actor, path, ~s|{"event":"logout"}\n|)

      {:ok, content} = Local.get(actor, path)
      assert content == ~s|{"event":"login"}\n{"event":"logout"}\n|
    end

    test "creates file if it doesn't exist", %{actor: actor} do
      path = ["data", "new.jsonl"]

      assert :ok == Local.append(actor, path, "first line\n")
      assert {:ok, "first line\n"} = Local.get(actor, path)
    end

    test "creates nested directories", %{actor: actor} do
      path = ["data", "nested", "audit.jsonl"]

      assert :ok == Local.append(actor, path, "content\n")
      assert Local.exists?(actor, path)
    end
  end

  describe "build_path/2" do
    test "global prefix cache goes to root", %{actor: actor} do
      path = Local.build_path(actor, ["cache", "oci", "sha256"])
      assert path == Path.join([@test_base_path, "cache", "oci", "sha256"])
    end

    test "tenant paths go verbatim under athanors/{athanor_id} (no namespace segment)", %{
      actor: actor
    } do
      path = Local.build_path(actor, ["data", "sub", "notes.txt"])

      assert path ==
               Path.join([
                 @test_base_path,
                 "athanors",
                 actor.athanor_id,
                 "data",
                 "sub",
                 "notes.txt"
               ])
    end

    test "component paths go under the actor's athanors/{athanor_id}/components", %{
      actor: actor
    } do
      path =
        Local.build_path(actor, [
          "components",
          "catalysts",
          "local",
          "t",
          "1.0.0"
        ])

      assert path ==
               Path.join([
                 @test_base_path,
                 "athanors",
                 actor.athanor_id,
                 "components",
                 "catalysts",
                 "local",
                 "t",
                 "1.0.0"
               ])
    end

    test "the seed bundle resolves under :seed_path, never the storage root", %{actor: actor} do
      path =
        Local.build_path(actor, ["seed", "components", "catalysts", "local"])

      bundle =
        Application.fetch_env!(:arca, :seed_path) |> Path.expand() |> Path.join("components")

      assert path == Path.join([bundle, "catalysts", "local"])
      refute String.starts_with?(path, @test_base_path)
    end

    test "the bare components root is the athanor's own components subtree", %{actor: actor} do
      assert Local.build_path(actor, ["components"]) ==
               Path.join([@test_base_path, "athanors", actor.athanor_id, "components"])
    end
  end

  describe "usage/2" do
    test "the empty-path walk counts the whole athanor, components included", %{actor: actor} do
      # The storage cap's one walk: a cap that bounds one subtree is not a
      # cap on the athanor.
      :ok = Local.put(actor, ["data", "a.txt"], "12345")

      :ok =
        Local.put(
          actor,
          ["components", "reagents", "local", "x", "1.0.0", "reagent.wasm"],
          "123"
        )

      assert {:ok, %{files: 2, bytes: 8}} = Local.usage(actor, [])

      assert {:ok, %{files: 1, bytes: 3}} =
               Local.usage(actor, ["components"])
    end

    test "a missing prefix is empty usage", %{actor: actor} do
      assert {:ok, %{files: 0, bytes: 0}} =
               Local.usage(actor, ["data", "never-written"])
    end

    @tag :unix
    test "an unreadable subtree fails CLOSED — the cap must see the error", %{actor: actor} do
      # Root skips the check: permission bits don't bind the superuser.
      if :os.type() == {:unix, :darwin} or System.get_env("USER") != "root" do
        :ok = Local.put(actor, ["data", "locked", "secret.txt"], "12345")
        locked = Local.build_path(actor, ["data", "locked"])
        File.chmod!(locked, 0o000)

        on_exit(fn -> File.chmod!(locked, 0o755) end)

        assert {:error, {:usage_walk, _path, :eacces}} =
                 Local.usage(actor, ["data"])

        # Listings stay lenient by design — only the cap's walk is strict.
        assert {:ok, _} = Local.list_recursive(actor, ["data"])
      end
    end
  end

  # ============================================================================
  # Edge Cases: Special Characters
  # ============================================================================

  describe "special characters in filenames" do
    test "handles spaces in filename", %{actor: actor} do
      path = ["data", "file with spaces.txt"]
      content = "content with spaces"

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
      assert Local.exists?(actor, path)
    end

    test "handles unicode in filename", %{actor: actor} do
      path = ["data", "文件名.txt"]
      content = "unicode content"

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "handles emoji in filename", %{actor: actor} do
      path = ["data", "📁data.json"]
      content = ~s|{"emoji": true}|

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "handles dashes and underscores", %{actor: actor} do
      path = ["data", "test-dir", "file_name-v1.2.3.txt"]
      content = "versioned content"

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "handles dots in directory names", %{actor: actor} do
      path = ["data", "v1.0.0", "release.txt"]
      content = "release notes"

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end
  end

  # ============================================================================
  # Edge Cases: Large Files
  # ============================================================================

  describe "large file handling" do
    test "handles 1MB+ file", %{actor: actor} do
      # Generate 1MB of content
      content = String.duplicate("x", 1_000_000)
      path = ["data", "big_file.bin"]

      assert :ok == Local.put(actor, path, content)
      assert {:ok, read_content} = Local.get(actor, path)
      assert byte_size(read_content) == 1_000_000
    end

    test "handles file with many small appends", %{actor: actor} do
      path = ["data", "many_lines.jsonl"]

      # Append 1000 small lines
      for i <- 1..1000 do
        :ok = Local.append(actor, path, ~s|{"line":#{i}}\n|)
      end

      {:ok, content} = Local.get(actor, path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 1000
    end
  end

  # ============================================================================
  # Edge Cases: Binary Content
  # ============================================================================

  describe "binary content handling" do
    test "handles null bytes in content", %{actor: actor} do
      content = <<0, 1, 2, 0, 3, 0, 0, 4>>
      path = ["data", "nulls.bin"]

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "handles all byte values 0-255", %{actor: actor} do
      content = :binary.list_to_bin(Enum.to_list(0..255))
      path = ["data", "all_bytes.bin"]

      assert :ok == Local.put(actor, path, content)
      assert {:ok, ^content} = Local.get(actor, path)
    end

    test "handles empty file", %{actor: actor} do
      path = ["data", "empty.bin"]

      assert :ok == Local.put(actor, path, "")
      assert {:ok, ""} = Local.get(actor, path)
    end
  end

  # ============================================================================
  # Edge Cases: Path Traversal Prevention
  # ============================================================================

  describe "path security" do
    test "rejects path traversal with ..", %{actor: actor} do
      # Path traversal segments are rejected with ArgumentError
      path = ["..", "etc", "passwd"]

      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Local.put(actor, path, "malicious")
      end
    end

    test "rejects empty path segments at the adapter", %{actor: actor} do
      # Adapters reject empty path segments.
      assert_raise ArgumentError, ~r/empty segments/, fn ->
        Local.put(actor, ["data", "", "file.txt"], "content")
      end
    end

    test "rejects segments with a leading slash (absolute-segment denylist)", %{actor: actor} do
      # Prima.PathSafety treats a leading "/" in any segment as an absolute
      # path fragment and fails closed rather than silently normalizing it.
      assert_raise ArgumentError, ~r/absolute segments are not allowed/, fn ->
        Local.put(actor, ["/test/", "/file.txt/"], "content")
      end

      # Trailing slashes without a leading one remain acceptable input.
      case Local.put(actor, ["data", "test/", "file.txt/"], "content") do
        :ok ->
          assert {:ok, _} = Local.get(actor, ["data", "test/", "file.txt/"])

        {:error, _} ->
          :ok
      end
    end
  end

  # ============================================================================
  # Edge Cases: Concurrent Operations
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent writes to different files succeed", %{actor: actor} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            path = ["data", "concurrent", "file_#{i}.txt"]
            content = "content #{i}"
            :ok = Local.put(actor, path, content)
            {:ok, read} = Local.get(actor, path)
            assert read == content
            i
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.sort(results) == Enum.to_list(1..10)
    end

    test "concurrent appends to same file", %{actor: actor} do
      path = ["data", "concurrent", "shared.jsonl"]

      # First create the file
      :ok = Local.put(actor, path, "")

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            :ok = Local.append(actor, path, "line #{i}\n")
          end)
        end

      Task.await_many(tasks, 5000)

      {:ok, content} = Local.get(actor, path)
      lines = String.split(content, "\n", trim: true)

      # All 50 lines should be present (order may vary)
      assert length(lines) == 50
    end

    test "concurrent reads are safe", %{actor: actor} do
      path = ["data", "concurrent", "readonly.txt"]
      content = "read me many times"
      :ok = Local.put(actor, path, content)

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            {:ok, read} = Local.get(actor, path)
            assert read == content
          end)
        end

      Task.await_many(tasks, 5000)
    end
  end

  # ============================================================================
  # Edge Cases: Deep Nesting
  # ============================================================================

  describe "deep nesting" do
    test "handles 20+ levels of nesting", %{actor: actor} do
      # Create a path with 20 directory levels
      deep_path = ["data" | Enum.map(1..20, &"level_#{&1}")] ++ ["deep_file.txt"]

      content = "very deep content"

      assert :ok == Local.put(actor, deep_path, content)
      assert {:ok, ^content} = Local.get(actor, deep_path)
      assert Local.exists?(actor, deep_path)
    end

    test "lists deeply nested directory", %{actor: actor} do
      base = ["data" | Enum.map(1..10, &"d#{&1}")]

      # Create multiple files in the deep directory
      for i <- 1..3 do
        path = base ++ ["file_#{i}.txt"]
        :ok = Local.put(actor, path, "content #{i}")
      end

      assert length(list_names(actor, base)) == 3
    end
  end

  describe "atomic put" do
    test "leaves no temp residue after a successful write", %{actor: actor} do
      :ok = Local.put(actor, ["data", "atomic", "target.txt"], "v1")
      :ok = Local.put(actor, ["data", "atomic", "target.txt"], "v2")

      assert {:ok, "v2"} = Local.get(actor, ["data", "atomic", "target.txt"])
      assert list_names(actor, ["data", "atomic"]) == ["target.txt"]
    end

    test "an overwrite failure cleans up its temp file", %{actor: actor} do
      # Renaming onto a non-empty directory fails on every platform, which
      # exercises the temp-cleanup path without needing to fake File.write.
      :ok =
        Local.put(actor, ["data", "atomic2", "occupied", "child.txt"], "x")

      assert {:error, _} =
               Local.put(actor, ["data", "atomic2", "occupied"], "clobber")

      # The directory survives untouched and the temp file (written next to
      # it, in atomic2/) is cleaned up.
      assert list_names(actor, ["data", "atomic2", "occupied"]) == ["child.txt"]
      assert list_names(actor, ["data", "atomic2"]) == ["occupied"]
    end
  end

  # The adapter surface has one listing callback; names are its first column.
  defp list_names(actor, path) do
    {:ok, entries} = Local.list_typed(actor, path)
    entries |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end
end
