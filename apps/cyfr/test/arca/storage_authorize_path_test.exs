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

  test "the seed bundle is readable only by server-internal contexts", %{a: a, seed: seed} do
    path = ["seed", "components", "catalysts", "local", "x", "0.1.0", "cyfr-manifest.json"]
    assert :ok = Arca.put(seed, path, "{}")

    assert {:error, :forbidden} = Arca.get(a, path)
    assert {:ok, "{}"} = Arca.get(seed, path)
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
      Arca.get(platform, ["notes", "x.txt"])
    end
  end

  test "tenant-prefixed data paths are untouched by the pin", %{a: a, b: b} do
    assert :ok = Arca.put(a, ["notes", "hello.txt"], "hi")
    assert {:ok, "hi"} = Arca.get(a, ["notes", "hello.txt"])
    # b's own tree simply lacks the file — it never sees a's.
    assert {:error, :not_found} = Arca.get(b, ["notes", "hello.txt"])
  end
end
