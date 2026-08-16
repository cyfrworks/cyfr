# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.ComponentHelpers do
  @moduledoc false

  @doc """
  Registers a test component in the component_store with the given manifest.
  Used by tests that need a registered component for target-ref existence
  checks. Pass a ctx to register under a specific tenant (defaults to the
  local test tenant).
  """
  def register_test_component(name, version, type, manifest, ctx \\ nil) do
    ctx = ctx || Sanctum.TestContext.local()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id:
        "test_#{:crypto.hash(:sha256, "#{name}#{version}#{type}#{ctx.athanor_id}") |> Base.encode16(case: :lower) |> binary_part(0, 16)}",
      name: name,
      version: version,
      component_type: type,
      description: "Test component",
      tags: "[]",
      digest: "sha256:test",
      size: 100,
      exports: "[]",
      manifest: Jason.encode!(manifest),
      publisher: "local",
      publisher_id: ctx.user_id,
      source: "local",
      signature_verified: false,
      inserted_at: now,
      updated_at: now
    }

    Arca.ComponentStorage.put_component(ctx, attrs)
  end
end
