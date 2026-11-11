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

  # `config/test.exs` configures a registry that is not cyfr.run: the
  # report goes to its moderators, named as the registry's.
  test "a report goes to the registry's moderators, never cyfr.run's", %{conn: conn, ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(
        ctx,
        Cyfr.Test.Guests.wasm(:reagent),
        %{
          name: "reportable",
          version: "1.0.0",
          type: "reagent",
          publisher: "local",
          description: "",
          tags: [],
          manifest: "{}"
        },
        source: "filesystem"
      )

    {view, html} = mount_athanor(conn, "/components/reagent:local.reportable:1.0.0")
    assert html =~ "Report this component to the registry&#39;s moderators"

    render_click(view, "open_report", %{})
    html = render(view)
    assert html =~ "Your report goes to the registry&#39;s moderators."
    refute html =~ "cyfr.run"
  end
end
