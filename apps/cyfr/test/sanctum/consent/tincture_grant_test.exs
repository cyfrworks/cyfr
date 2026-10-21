# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.TinctureGrantTest do
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Components

  # The component domain's facts, but for a version whose stored manifest
  # the verified resolution finds does not decode.
  defmodule DamagedManifest do
    @moduledoc false
    @behaviour Sanctum.Consent.Components

    for {name, arity} <- Sanctum.Consent.Components.behaviour_info(:callbacks),
        name != :resolve_verified do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(Compendium.ConsentFacts, unquote(name), [unquote_splicing(args)])
    end

    def resolve_verified(_ctx, row),
      do: {:error, {:corrupt, {:manifest, Prima.ComponentRow.node_key(row)}}}
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  # A tincture version as the store holds it.
  defp tincture_row!(ctx, name) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "frame" => %{"capabilities" => []}}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
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

    "tincture:local.#{name}"
  end

  test "a version whose stored manifest does not decode is refused as that damage", %{ctx: ctx} do
    ref = tincture_row!(ctx, "grant-damaged")
    Sanctum.Test.ConsentFixtures.grant_tincture!(ctx, ref)

    # Restored by on_exit, registered before the change.
    real = Components.impl!()
    on_exit(fn -> Components.install!(real) end)
    Components.install!(DamagedManifest)

    assert {:error, {:refused, {:corrupt, {:manifest, ^ref}}}} =
             Sanctum.Consent.tincture_grant(ctx, ref <> ":1.0.0")
  end
end
