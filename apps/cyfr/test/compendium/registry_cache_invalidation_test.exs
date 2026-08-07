# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryCacheInvalidationTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry
  alias Sanctum.Context

  # Opus.ComponentCache writes compiled-component entries under NORMALIZED
  # tenant coordinates ({:compiled_component, "local", "default", ref} for a
  # nil/"" org), while :component_meta entries are written under the raw ctx
  # coordinates. The registry sweep must use each writer's convention — a
  # raw-key sweep of :compiled_component left stale compiled components
  # serving for their full TTL after a re-register or delete.

  test "sweeps normalized compiled-component keys for a raw-coordinate ctx" do
    ctx = %Context{org_id: "", project_id: "", user_id: "test", scope: :project}

    # Mirrors Opus.ComponentCache's normalized write key
    normalized_key = {:compiled_component, "local", "default", "formula:local.sweep-test:1.0.0"}
    Arca.Cache.put(normalized_key, {"digest", :fake_component}, 60_000)

    assert {:ok, _} = Arca.Cache.get(normalized_key)

    Registry.invalidate_executor_caches(ctx)

    assert :miss = Arca.Cache.get(normalized_key)
  end

  test "still sweeps raw-coordinate component_meta keys" do
    ctx = %Context{org_id: "", project_id: "", user_id: "test", scope: :project}

    # Mirrors Opus.Executor's raw write key
    raw_meta_key = {:component_meta, "", "", "formula:local.sweep-test:1.0.0"}
    Arca.Cache.put(raw_meta_key, %{some: :meta}, 60_000)

    assert {:ok, _} = Arca.Cache.get(raw_meta_key)

    Registry.invalidate_executor_caches(ctx)

    assert :miss = Arca.Cache.get(raw_meta_key)
  end

  test "sweep for a normal tenant ctx clears both cache families" do
    ctx = %Context{org_id: "local", project_id: "default", user_id: "test", scope: :project}

    compiled_key = {:compiled_component, "local", "default", "formula:local.sweep-two:1.0.0"}
    meta_key = {:component_meta, "local", "default", "formula:local.sweep-two:1.0.0"}
    Arca.Cache.put(compiled_key, {"digest", :fake_component}, 60_000)
    Arca.Cache.put(meta_key, %{some: :meta}, 60_000)

    Registry.invalidate_executor_caches(ctx)

    assert :miss = Arca.Cache.get(compiled_key)
    assert :miss = Arca.Cache.get(meta_key)
  end
end
