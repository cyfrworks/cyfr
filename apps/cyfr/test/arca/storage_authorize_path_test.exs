# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageAuthorizePathTest do
  @moduledoc """
  The component tree is shared by every athanor; `Arca` pins each context to
  its own subtree before any adapter call, so no athanor can read another's
  bytes and only server-internal contexts see the seed bundle.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Context

  setup do
    base = Path.join(System.tmp_dir!(), "arca_authz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    prev_base = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)

    # The bundle test writes through the bundle branch of build_path/2;
    # keep those bytes out of the suite-shared bundle root.
    bundle = Path.join(base, "bundle")
    File.mkdir_p!(bundle)
    prev_bundle = Application.get_env(:cyfr, :bundle_path)
    Application.put_env(:cyfr, :bundle_path, bundle)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :bundle_path, prev_bundle)
      File.rm_rf!(base)
    end)

    a =
      Context.build(user_id: "alice", athanor_id: "ath_a", permissions: [:*], authenticated: true)

    b = Context.build(user_id: "bob", athanor_id: "ath_b", permissions: [:*], authenticated: true)
    seed = Sanctum.internal_context(user_id: "_seed", athanor_id: "ath_a", scope: :athanor)

    {:ok, a: a, b: b, seed: seed}
  end

  test "an athanor cannot read, list, or write another athanor's components", %{a: a, b: b} do
    path = ["components", "ath_a", "catalysts", "local", "x", "0.1.0", "cyfr-manifest.json"]
    assert :ok = Arca.put(a, path, "{}")

    assert {:error, :forbidden} = Arca.get(b, path)
    assert {:error, :forbidden} = Arca.list_recursive(b, ["components", "ath_a"])
    assert {:error, :forbidden} = Arca.put(b, path, "overwritten")
    refute Arca.exists?(b, path)

    # The owner still reads its own bytes.
    assert {:ok, "{}"} = Arca.get(a, path)
  end

  test "the seed bundle is readable only by server-internal contexts", %{a: a, seed: seed} do
    path = ["components", "_bundle", "catalysts", "local", "x", "0.1.0", "cyfr-manifest.json"]
    assert :ok = Arca.put(seed, path, "{}")

    assert {:error, :forbidden} = Arca.get(a, path)
    assert {:ok, "{}"} = Arca.get(seed, path)
  end

  test "a bare components listing is refused for everyone — it has no physical root", %{a: a} do
    platform =
      Context.build(user_id: "op", scope: :platform, athanor_id: nil, authenticated: true)

    # The tenant pin refuses a member outright.
    assert {:error, :forbidden} = Arca.list_recursive(a, ["components"])
    assert {:error, :forbidden} = Arca.Storage.authorize_path(a, ["components"])

    # A platform context reaches every athanor's subtree, but the unified
    # layout has no single components root — roster-driven code enumerates
    # athanors instead, so even platform gets a typed refusal, not a raise.
    assert {:error, :forbidden} = Arca.Storage.authorize_path(platform, ["components"])
    assert {:error, :forbidden} = Arca.list_recursive(platform, ["components"])
    assert :ok = Arca.Storage.authorize_path(platform, ["components", "ath_a"])
  end

  test "tenant-prefixed data paths are untouched by the pin", %{a: a, b: b} do
    assert :ok = Arca.put(a, ["notes", "hello.txt"], "hi")
    assert {:ok, "hi"} = Arca.get(a, ["notes", "hello.txt"])
    # b's own tree simply lacks the file — it never sees a's.
    assert {:error, :not_found} = Arca.get(b, ["notes", "hello.txt"])
  end
end
