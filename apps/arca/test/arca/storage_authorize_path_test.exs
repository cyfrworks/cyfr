# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageAuthorizePathTest do
  @moduledoc """
  Every tenant path takes its athanor from the ACTOR, so isolation is
  structural — no path spelling names another athanor's tree. What
  `authorize_path/2` still guards is the server's own: the seed bundle and
  the global roots, and the authority it reads for them is
  `Cyfr.Actor.system`, which is not a wire member and so cannot be
  claimed by anything a worker returns.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Actor

  setup do
    base = Path.join(System.tmp_dir!(), "arca_authz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    prev_base = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    # The bundle test writes through the seed branch of build_path/2;
    # keep those bytes out of the suite-shared seed tree.
    seed = Path.join(base, "seed")
    File.mkdir_p!(Path.join(seed, "components"))
    prev_seed = Application.get_env(:arca, :seed_path)
    Application.put_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    a = %{Actor.in_athanor("ath_a") | user_id: "alice", authenticated: true}
    b = %{Actor.in_athanor("ath_b") | user_id: "bob", authenticated: true}

    # The server's own actor narrowed to one athanor: `system: true` is
    # what opens the seed and global roots, `scope: :athanor` is what
    # keeps its tenant reads inside this estate.
    seed = %{Actor.system() | user_id: "_seed", athanor_id: "ath_a", scope: :athanor}

    {:ok, a: a, b: b, seed: seed}
  end

  test "component paths are tenant-relative — the actor is the only addressing", %{a: a, b: b} do
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

  test "the seed bundle is read-only, and readable only by a system actor",
       %{a: a, seed: seed} do
    path = ["seed", "components", "catalysts", "local", "x", "0.1.0", "cyfr-manifest.json"]

    # Seed is install media: writes are refused at the seam for EVERY
    # actor, the system's included — fixtures land on disk, the way
    # install media does.
    assert {:error, :seed_read_only} = Arca.put(seed, path, "{}")
    assert {:error, :seed_read_only} = Arca.put(a, path, "{}")
    assert {:error, :seed_read_only} = Arca.delete(seed, path)
    assert {:error, :seed_read_only} = Arca.delete_tree(seed, ["seed", "components"])

    seed_file =
      :arca
      |> Application.fetch_env!(:seed_path)
      |> Path.join("components/catalysts/local/x/0.1.0/cyfr-manifest.json")

    File.mkdir_p!(Path.dirname(seed_file))
    File.write!(seed_file, "{}")

    assert {:error, :forbidden} = Arca.get(a, path)
    assert {:ok, "{}"} = Arca.get(seed, path)
  end

  test "a refused seed write leaves the tree byte-identical on disk", %{seed: seed} do
    seed_root = Application.fetch_env!(:arca, :seed_path)
    seed_file = Path.join(seed_root, "components/catalysts/local/y/0.1.0/cyfr-manifest.json")
    File.mkdir_p!(Path.dirname(seed_file))
    File.write!(seed_file, ~s({"shipped": true}))

    snapshot = fn ->
      Cyfr.Test.SourceTree.files!(Path.join(seed_root, "**"))
      |> Enum.sort()
      |> Enum.map(&{&1, File.dir?(&1) || Cyfr.Test.SourceTree.read(&1)})
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
    assert {:error, :forbidden} = Arca.put(a, ["scratch", "hello.txt"], "hi")
    assert {:error, :forbidden} = Arca.get(a, ["scratch", "hello.txt"])
    assert {:error, :forbidden} = Arca.list_recursive(a, ["guest", "x"])
    refute Arca.exists?(a, ["scratch", "hello.txt"])
  end

  test "multi-level string segments name the same object as their split spelling", %{a: a} do
    # One spelling per object: the facade flattens before the gate, so the
    # Local adapter (which joins with the filesystem) and the S3 adapter
    # (which joins into a key) can never disagree.
    assert :ok = Arca.put(a, ["data/sub/dir", "f.txt"], "flat")
    assert {:ok, "flat"} = Arca.get(a, ["data", "sub", "dir", "f.txt"])
    assert Arca.exists?(a, ["data", "sub/dir/f.txt"])

    # Split artifacts (trailing slashes) are dropped, not stored.
    assert :ok = Arca.put(a, ["data/", "t.txt"], "x")
    assert {:ok, "x"} = Arca.get(a, ["data", "t.txt"])
  end

  test "the in-flight temp suffix is a reserved name for writes", %{a: a} do
    # `.tmp.N` is the Local adapter's write marker — invisible to listings
    # and the usage walk, reaped by the sweeper. A caller-chosen tmp name
    # would be a hidden, uncounted object; the pattern means one thing.
    assert {:error, :reserved_name} = Arca.put(a, ["data", "blob.tmp.1"], "x")
    assert {:error, :reserved_name} = Arca.append(a, ["data", "log.tmp.99"], "x")
    refute Arca.exists?(a, ["data", "blob.tmp.1"])

    # Reserved at ANY depth: a tmp-named directory would hide its whole
    # subtree from listings and the usage walk — an uncounted object the
    # sweeper couldn't reclaim. Archive ingresses store remote-controlled
    # paths, so this is also what stops a hostile tarball from planting
    # an invisible subtree.
    assert {:ok, usage_before} = Arca.usage(a, [])
    assert {:error, :reserved_name} = Arca.put(a, ["data", "x.tmp.1", "a.txt"], "x")
    assert {:error, :reserved_name} = Arca.append(a, ["data", "x.tmp.2", "log"], "x")
    assert {:error, :reserved_name} = Arca.put(a, ["data/x.tmp.3", "a.txt"], "x")
    refute Arca.exists?(a, ["data", "x.tmp.1", "a.txt"])
    assert {:ok, ^usage_before} = Arca.usage(a, [])

    # Only the exact suffix is reserved.
    assert :ok = Arca.put(a, ["data", "blob.tmp"], "x")
    assert :ok = Arca.put(a, ["data", "tmp.1"], "x")
    assert :ok = Arca.put(a, ["data", "sub.tmp", "nested.txt"], "x")
  end

  test "an actor without an athanor cannot touch tenant storage at all" do
    platform = Actor.system()

    # Platform opens an athanor the way it does for rows — with an actor
    # narrowed to it. Unnarrowed, tenant paths are nowhere: the facade
    # refuses before any adapter is asked, and `""` is refused with nil.
    assert {:error, :no_athanor} = Arca.list_recursive(platform, ["components"])
    assert {:error, :no_athanor} = Arca.get(platform, ["data", "x.txt"])
    assert {:error, :no_athanor} = Arca.put(platform, ["data", "x.txt"], "x")

    assert {:error, :no_athanor} =
             Arca.get(%{platform | athanor_id: ""}, ["data", "x.txt"])

    # The raise stays as the backstop under the facade, for anything that
    # reaches an adapter directly.
    assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
      Arca.Storage.tenant_segments(platform)
    end
  end

  test "the global roots are the system's, and an ordinary actor may not touch them", %{a: a} do
    system = Actor.system()
    blob = ["cache", "oci", "sha256_g9"]

    # `system: true` is the authority `authorize_path/2` reads for a
    # global root — not `scope`, and not anything a caller presented.
    assert :ok = Arca.put(system, blob, "bytes")
    assert {:ok, "bytes"} = Arca.get(system, blob)

    # An ordinary tenant actor is refused, whatever its athanor, and a
    # platform-scope actor that is NOT the system is refused too: the two
    # authorities are separate meanings.
    assert {:error, :forbidden} = Arca.get(a, blob)
    assert {:error, :forbidden} = Arca.put(a, blob, "mine")

    platform_only = %{Actor.in_athanor("ath_a") | scope: :platform}
    assert {:error, :forbidden} = Arca.get(platform_only, blob)
    assert {:error, :forbidden} = Arca.put(platform_only, blob, "mine")

    # And the bytes the system wrote are still what it wrote.
    assert {:ok, "bytes"} = Arca.get(system, blob)
    assert :ok = Arca.delete(system, blob)
  end

  test "tenant-prefixed data paths are untouched by the pin", %{a: a, b: b} do
    assert :ok = Arca.put(a, ["data", "hello.txt"], "hi")
    assert {:ok, "hi"} = Arca.get(a, ["data", "hello.txt"])
    # b's own tree simply lacks the file — it never sees a's.
    assert {:error, :not_found} = Arca.get(b, ["data", "hello.txt"])
  end
end
