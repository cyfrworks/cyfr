# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryCacheInvalidationTest do
  use ExUnit.Case, async: false

  alias Arca.Cache.Keys
  alias Compendium.Registry
  alias Sanctum.Context

  # Opus.ComponentCache and Opus.Executor write their cache entries under the
  # shapes in Arca.Cache.Keys; the registry sweep must use the same shapes or a
  # re-register / delete leaves stale compiled components serving for their
  # full TTL. Both families are keyed by the athanor.

  test "sweep clears both cache families for the athanor" do
    ctx = %Context{athanor_id: "ath_sweep", user_id: "test", scope: :athanor}

    compiled_key = Keys.compiled_component("ath_sweep", "formula:local.sweep-two:1.0.0")
    meta_key = Keys.component_meta("ath_sweep", "formula:local.sweep-two:1.0.0")
    Arca.Cache.put(compiled_key, {"digest", :fake_component}, 60_000)
    Arca.Cache.put(meta_key, %{some: :meta}, 60_000)

    Registry.invalidate_executor_caches(ctx)

    assert :miss = Arca.Cache.get(compiled_key)
    assert :miss = Arca.Cache.get(meta_key)
  end

  test "sweep leaves another athanor's entries alone" do
    ctx = %Context{athanor_id: "ath_sweep", user_id: "test", scope: :athanor}

    other_compiled = Keys.compiled_component("ath_other", "formula:local.sweep-two:1.0.0")
    other_meta = Keys.component_meta("ath_other", "formula:local.sweep-two:1.0.0")
    Arca.Cache.put(other_compiled, {"digest", :fake_component}, 60_000)
    Arca.Cache.put(other_meta, %{some: :meta}, 60_000)

    Registry.invalidate_executor_caches(ctx)

    assert {:ok, _} = Arca.Cache.get(other_compiled)
    assert {:ok, _} = Arca.Cache.get(other_meta)
  end
end
