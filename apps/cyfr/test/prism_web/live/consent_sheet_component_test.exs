# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentSheetComponentTest do
  @moduledoc """
  The consent sheet, the system layer's grant body, walks plan → preview
  through `PrismWeb.Ops.call_tool/3`, whose dialect is `tool/action` — a
  dot-spelled name silently misses the registry and every call fails with
  "Unknown tool" — and the layer commits the walk through the same
  adapter. These tests render the component against the real registry so
  a dialect drift (or a retired verb) fails here instead of in the
  operator's browser, and hold that no page draws it but the layer.
  """

  # The plan walk hits the DB, including from tasks the dispatcher spawns —
  # PrismWeb.ConnCase checks the sandbox out in shared mode.
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Context

  defp oidc_ctx do
    Context.build(
      user_id: "consent_sheet_test_user",
      namespace: "consent_sheet_test_user",
      athanor_id: "ath_test",
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  test "given no walk, the sheet's plan call reaches the profile tool through the registry" do
    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: "publisher/does-not-exist@0.0.1",
        context: oidc_ctx()
      )

    # The plan fails on the nonexistent ref — that's expected. What must
    # never appear is a registry miss: that means the component and the
    # helper disagree on the tool-name dialect again.
    refute html =~ "Unknown tool"
  end

  test "given the prompt's walk, the sheet draws it and reads nothing" do
    walk = %{
      ref: "tincture:local.sheet-probe",
      plan: %{
        plan_token: "not-read",
        expected_consent_revision: 0,
        needs: [%{need: "api_key", reason: "to reach the service"}],
        candidates: [%{id: "vlt_1", name: "Service key", field_names: ["SERVICE_KEY"]}],
        caps: nil
      },
      preview: %{
        v: 1,
        rows: [
          %{
            "kind" => "credential",
            "node" => "tincture:local.sheet-probe",
            "narrowed" => false,
            "values" => %{
              "name" => "Service key",
              "edge" => "@ingress",
              "fields" => ["SERVICE_KEY"],
              "scopes" => []
            }
          }
        ],
        origins: ["interactive"],
        proof: "p",
        commit_digest: "d"
      },
      decisions: %{
        "ref" => "tincture:local.sheet-probe",
        "bindings" => [%{"need" => "api_key", "entry_id" => "vlt_1"}]
      }
    }

    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: walk.ref,
        walk: walk,
        context: oidc_ctx(),
        athanor_name: "Home"
      )

    assert html =~ "to reach the service"
    assert html =~ ~r/data-row="credential"[^>]*>\s*<span[^>]*>Service key<\/span>/
    assert html =~ "tincture:local.sheet-probe&#39;s own calls"
    assert html =~ "tincture:local.sheet-probe · in Home"
    assert html =~ ~r/aria-pressed="true"[^>]*>\s*Service key/
  end

  test "a plan whose closure is unresolved names what is missing, and draws no rows" do
    walk = %{
      ref: "tincture:local.sheet-orphan",
      plan: %{
        plan_token: "not-read",
        expected_consent_revision: 0,
        needs: [],
        candidates: [],
        rows: [%{"kind" => "limits", "node" => "tincture:local.sheet-orphan"}],
        unresolved: %{reason: "unresolvable_dependency", missing: "reagent:local.absent"}
      },
      preview: nil,
      decisions: %{"ref" => "tincture:local.sheet-orphan", "bindings" => []}
    }

    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: walk.ref,
        walk: walk,
        context: oidc_ctx()
      )

    assert html =~ ~s(data-test="grant-unresolved")
    assert html =~ "reagent:local.absent is missing"
    refute html =~ ~s(data-test="grant-rows")
    refute html =~ ~s(data-test="grant-origins")
  end

  test "what changed is worded against the person's grant, never as the component widening" do
    walk = %{
      ref: "tincture:local.sheet-delta",
      plan: %{
        plan_token: "not-read",
        expected_consent_revision: 1,
        needs: [],
        candidates: [],
        rows: [],
        shape_diff: [
          %{
            capability: "egress.domains",
            change: :changed,
            added: ["b.example"],
            removed: ["old.example"]
          }
        ]
      },
      preview: %{v: 1, rows: [], origins: ["interactive"], proof: "p", commit_digest: "d"},
      decisions: %{"ref" => "tincture:local.sheet-delta", "bindings" => []}
    }

    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: walk.ref,
        walk: walk,
        context: oidc_ctx()
      )

    assert html =~ "asks for b.example, which your grant does not give"
    assert html =~ "no longer asks for old.example"
    refute html =~ "now wants"
  end

  test "every verb of the walk is a registered profile action" do
    {:ok, tool} = Grimoire.get_tool("profile")

    enum = get_in(tool, ["inputSchema", "properties", "action", "enum"]) || []

    # The sheet plans and previews; the layer commits what it holds.
    for action <- ~w(plan preview commit) do
      assert action in enum,
             "a grant drives profile.#{action}, which the profile tool no longer registers"
    end

    layer = File.read!(Path.expand("../../../lib/prism_web/live/system_layer.ex", __DIR__))
    assert layer =~ ~s("profile/commit")
  end

  test "no page draws the sheet but the system layer" do
    live = Path.expand("../../../lib/prism_web/live", __DIR__)

    drawn =
      for path <- Path.wildcard(Path.join(live, "**/*.ex")),
          File.read!(path) =~
            ~r/module=\{(PrismWeb\.)?ConsentSheetComponent\}|ConsentSheetComponent\./,
          do: Path.relative_to(path, live)

    assert drawn == ["system_layer.ex"]
  end
end
