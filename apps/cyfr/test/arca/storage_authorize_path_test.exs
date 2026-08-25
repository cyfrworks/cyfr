# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageAuthorizePathTest do
  @moduledoc """
  Every tenant path takes its athanor from the context, so isolation is
  structural — no path spelling names another athanor's tree. What
  `authorize_path/2` still guards is the server's own: the seed bundle and
  the global roots.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    base = Path.join(System.tmp_dir!(), "arca_authz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    prev_base = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)

    # The bundle test writes through the seed branch of build_path/2;
    # keep those bytes out of the suite-shared seed tree.
    seed = Path.join(base, "seed")
    File.mkdir_p!(Path.join(seed, "components"))
    prev_seed = Application.get_env(:cyfr, :seed_path)
    Application.put_env(:cyfr, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    a =
      Context.build(user_id: "alice", athanor_id: "ath_a", permissions: [:*], authenticated: true)

    b = Context.build(user_id: "bob", athanor_id: "ath_b", permissions: [:*], authenticated: true)
    seed = Sanctum.internal_context(user_id: "_seed", athanor_id: "ath_a", scope: :athanor)

    {:ok, a: a, b: b, seed: seed}
  end

  test "component paths are tenant-relative — the context is the only addressing", %{a: a, b: b} do
    path = ["components", "catalysts", "local", "x", "0.1.0", "cyfr-manifest.json"]
    assert :ok = Arca.put(a, path, "{}")

    # The same spelling under b's context is b's own (empty) tree.
    assert {:error, :not_found} = Arca.get(b, path)
    refute Arca.exists?(b, path)
    assert {:ok, []} = Arca.list_recursive(b, ["components"])

    # b writing the same spelling lands in b's tree and leaves a's alone.
    assert :ok = Arca.put(b, path, "mine")
    assert {:ok, "{}"} = Arca.get(a, path)
    assert {:ok, "mine"} = Arca.get(b, path)
  end

  test "the seed bundle is read-only, and readable only by server-internal contexts",
       %{a: a, seed: seed} do
    path = ["seed", "components", "catalysts", "local", "x", "0.1.0", "cyfr-manifest.json"]

    # Seed is install media: writes are refused at the seam for EVERY
    # context, system ones included — fixtures land on disk, the way
    # install media does.
    assert {:error, :seed_read_only} = Arca.put(seed, path, "{}")
    assert {:error, :seed_read_only} = Arca.put(a, path, "{}")
    assert {:error, :seed_read_only} = Arca.delete(seed, path)
    assert {:error, :seed_read_only} = Arca.delete_tree(seed, ["seed", "components"])

    seed_file =
      :cyfr
      |> Application.fetch_env!(:seed_path)
      |> Path.join("components/catalysts/local/x/0.1.0/cyfr-manifest.json")

    File.mkdir_p!(Path.dirname(seed_file))
    File.write!(seed_file, "{}")

    assert {:error, :forbidden} = Arca.get(a, path)
    assert {:ok, "{}"} = Arca.get(seed, path)
  end

  test "a refused seed write leaves the tree byte-identical on disk", %{seed: seed} do
    seed_root = Application.fetch_env!(:cyfr, :seed_path)
    seed_file = Path.join(seed_root, "components/catalysts/local/y/0.1.0/cyfr-manifest.json")
    File.mkdir_p!(Path.dirname(seed_file))
    File.write!(seed_file, ~s({"shipped": true}))

    snapshot = fn ->
      Path.wildcard(Path.join(seed_root, "**"))
      |> Enum.sort()
      |> Enum.map(&{&1, File.dir?(&1) || File.read!(&1)})
    end

    before = snapshot.()
    path = ["seed", "components", "catalysts", "local", "y", "0.1.0", "cyfr-manifest.json"]

    # The error tuple alone would not prove the tree survived — a refusal
    # that landed after a partial write would still return it.
    assert {:error, :seed_read_only} = Arca.put(seed, path, "clobbered")
    assert {:error, :seed_read_only} = Arca.append(seed, path, "clobbered")
    assert {:error, :seed_read_only} = Arca.delete(seed, path)
    assert {:error, :seed_read_only} = Arca.delete_tree(seed, ["seed", "components"])

    assert snapshot.() == before
  end

  test "an unknown first segment is refused, never minted as a new subtree", %{a: a} do
    assert {:error, :forbidden} = Arca.put(a, ["notes", "hello.txt"], "hi")
    assert {:error, :forbidden} = Arca.get(a, ["notes", "hello.txt"])
    assert {:error, :forbidden} = Arca.list_recursive(a, ["data", "x"])
    refute Arca.exists?(a, ["notes", "hello.txt"])
  end

  test "multi-level string segments name the same object as their split spelling", %{a: a} do
    # One spelling per object: the facade flattens before the gate, so the
    # Local adapter (which joins with the filesystem) and the S3 adapter
    # (which joins into a key) can never disagree.
    assert :ok = Arca.put(a, ["guest/sub/dir", "f.txt"], "flat")
    assert {:ok, "flat"} = Arca.get(a, ["guest", "sub", "dir", "f.txt"])
    assert Arca.exists?(a, ["guest", "sub/dir/f.txt"])

    # Split artifacts (trailing slashes) are dropped, not stored.
    assert :ok = Arca.put(a, ["guest/", "t.txt"], "x")
    assert {:ok, "x"} = Arca.get(a, ["guest", "t.txt"])
  end

  test "the in-flight temp suffix is a reserved name for writes", %{a: a} do
    # `.tmp.N` is the Local adapter's write marker — invisible to listings
    # and the usage walk, reaped by the sweeper. A caller-chosen tmp name
    # would be a hidden, uncounted object; the pattern means one thing.
    assert {:error, :reserved_name} = Arca.put(a, ["guest", "blob.tmp.1"], "x")
    assert {:error, :reserved_name} = Arca.append(a, ["guest", "log.tmp.99"], "x")
    refute Arca.exists?(a, ["guest", "blob.tmp.1"])

    # Only the exact suffix is reserved.
    assert :ok = Arca.put(a, ["guest", "blob.tmp"], "x")
    assert :ok = Arca.put(a, ["guest", "tmp.1"], "x")
  end

  test "a context without an athanor cannot touch tenant storage at all" do
    platform =
      Context.build(user_id: "op", scope: :platform, athanor_id: nil, authenticated: true)

    # Platform opens an athanor the way it does for rows — with a context
    # focused on it. Unfocused, tenant paths are nowhere: fail closed.
    assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
      Arca.list_recursive(platform, ["components"])
    end

    assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
      Arca.get(platform, ["guest", "x.txt"])
    end
  end

  test "tenant-prefixed data paths are untouched by the pin", %{a: a, b: b} do
    assert :ok = Arca.put(a, ["guest", "hello.txt"], "hi")
    assert {:ok, "hi"} = Arca.get(a, ["guest", "hello.txt"])
    # b's own tree simply lacks the file — it never sees a's.
    assert {:error, :not_found} = Arca.get(b, ["guest", "hello.txt"])
  end
end
