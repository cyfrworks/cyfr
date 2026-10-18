# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.PlanMissingVersionTest do
  @moduledoc """
  A plan for a version the athanor does not hold names that version in
  its refusal, not the component it does hold.
  """

  use ExUnit.Case, async: false

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "a missing selected version names that version, not the installed component line",
       %{ctx: ctx} do
    name = "selected-version"
    name_ref = "tincture:local.#{name}"
    requested = name_ref <> ":9.9.9"

    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html"}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _} =
             Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
               id: "cmp_selected_#{System.unique_integer([:positive])}",
               name: name,
               version: "1.0.0",
               component_type: "tincture",
               description: name,
               tags: "[]",
               digest: digest,
               release_digest: release,
               size: 100,
               exports: "[]",
               manifest: Jason.encode!(manifest),
               publisher: "local",
               publisher_id: "local|local|testns",
               source: Compendium.Source.filesystem(),
               signature_verified: false,
               inserted_at: now,
               updated_at: now
             })

    assert {:ok, %{version: "1.0.0"}} =
             Sanctum.Consent.Plan.fetch_component(ctx, name_ref)

    assert {:error, {:not_found, {:component, ^requested}} = refusal} =
             Sanctum.Consent.Plan.plan(ctx, %{ref: requested})

    assert Prima.Refusal.classify(refusal).message == "Component not found: #{requested}"
  end
end
