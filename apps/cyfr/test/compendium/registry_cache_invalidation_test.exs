# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryCacheInvalidationTest do
  use ExUnit.Case, async: false

  alias Arca.Cache.Keys
  alias Compendium.Registry
  alias Sanctum.Context

  # Opus.Executor writes component metadata under the shape in
  # Arca.Cache.Keys; the registry sweep must use the same shape or a
  # re-register / delete leaves stale metadata serving for its full TTL.
  # Compiled components are content-addressed (keyed by digest) and are not
  # the sweep's business: a changed component is a changed digest.

  test "sweep clears the athanor's component metadata and nothing else" do
    ctx = %Context{athanor_id: "ath_sweep", user_id: "test", scope: :athanor}

    meta_key = Keys.component_meta("ath_sweep", "formula:local.sweep-two:1.0.0")
    compiled_key = Keys.compiled_component("sha256:shared-bytes")
    Arca.Cache.put(meta_key, %{some: :meta}, 60_000)
    Arca.Cache.put(compiled_key, {1, :fake_component}, 60_000)

    Registry.invalidate_executor_caches(ctx)

    assert :miss = Arca.Cache.get(meta_key)
    assert {:ok, _} = Arca.Cache.get(compiled_key)
  end

  test "sweep leaves another athanor's metadata alone" do
    ctx = %Context{athanor_id: "ath_sweep", user_id: "test", scope: :athanor}

    other_meta = Keys.component_meta("ath_other", "formula:local.sweep-two:1.0.0")
    Arca.Cache.put(other_meta, %{some: :meta}, 60_000)

    Registry.invalidate_executor_caches(ctx)

    assert {:ok, _} = Arca.Cache.get(other_meta)
  end
end
