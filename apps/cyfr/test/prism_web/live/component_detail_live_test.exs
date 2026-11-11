# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentDetailLiveTest do
  @moduledoc """
  The component detail page renders what `component/inspect` answers,
  its dependencies as the tree the resolver reads.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    conn = log_in_user(conn, test_user())
    ctx = %{Sanctum.TestContext.local(:prism) | athanor_id: seated_athanor().id}
    %{conn: conn, ctx: ctx}
  end

  test "a component with dependencies renders each one", %{conn: conn, ctx: ctx} do
    manifest = %{
      "dependencies" => %{
        "static" => [
          %{"ref" => "reagent:local.missing-dep:1.0.0"},
          %{"ref" => "reagent:local.optional-dep:1.0.0", "optional" => true}
        ]
      }
    }

    {:ok, _} =
      Compendium.Registry.publish_bytes(
        ctx,
        Cyfr.Test.Guests.wasm(:reagent),
        %{
          name: "with-deps",
          version: "1.0.0",
          type: "reagent",
          publisher: "local",
          description: "",
          tags: [],
          manifest: Jason.encode!(manifest)
        },
        source: "filesystem"
      )

    {_view, html} = mount_athanor(conn, "/components/reagent:local.with-deps:1.0.0")
    assert html =~ "Dependencies"
    assert html =~ "reagent:local.missing-dep:1.0.0"
    assert html =~ ~r{optional-dep:1\.0\.0</span>\s*<span[^>]*>optional</span>}
    refute html =~ ~r{missing-dep:1\.0\.0</span>\s*<span[^>]*>optional</span>}
  end
end
