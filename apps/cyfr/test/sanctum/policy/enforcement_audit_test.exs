# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.EnforcementAuditTest do
  # §4.5: the enforcement row stores the runtime facts and JOINS the
  # attribution. What a chain knows goes in the row; who granted it, when
  # and how comes from the immutable consent at read.
  use ExUnit.Case, async: false

  alias Sanctum.Policy.Enforcement

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp seed_consent!(ctx) do
    profile_id = "prof-audit-#{System.unique_integer([:positive])}"

    {:ok, consent} =
      Arca.ConsentStorage.mint_profile_with_revision(
        %{
          id: profile_id,
          org_id: ctx.org_id,
          project_id: ctx.project_id,
          source_ref: "formula:local.audited",
          kind: "owner",
          label: "default",
          status: "active"
        },
        %{
          org_id: ctx.org_id,
          profile_id: profile_id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy: "{}",
          activation: "{}",
          granted_by: "operator@example",
          granted_via: "interactive"
        },
        []
      )

    consent
  end

  test "the runtime facts are stored on the row", %{ctx: ctx} do
    consent = seed_consent!(ctx)

    :ok =
      Enforcement.record(%{
        ctx: ctx,
        component_ref: "catalyst:local.gmail",
        component_type: :catalyst,
        event_type: :policy_consultation,
        decision: :allowed,
        execution_id: "exec_audit",
        consent_id: consent.id,
        activation_digest: "sha256:activation",
        dep_ref: "catalyst:local.gmail",
        need: "@ingress",
        cursor_state: "bound:formula:local.audited",
        chain: ["formula:local.audited", "catalyst:local.gmail"],
        value_source: "vault:vlt_123"
      })

    [row] = Arca.PolicyLog.list(org_id: ctx.org_id, project_id: ctx.project_id, limit: 1)

    assert row.consent_id == consent.id
    assert row.activation_digest == "sha256:activation"
    assert row.dep_ref == "catalyst:local.gmail"
    assert row.need == "@ingress"
    assert row.cursor_state == "bound:formula:local.audited"
    assert row.value_source == "vault:vlt_123"
    # Lists have no native column on either adapter — text + Jason.
    assert Jason.decode!(row.chain) == ["formula:local.audited", "catalyst:local.gmail"]
  end

  test "attribution is joined from the consent, not copied", %{ctx: ctx} do
    consent = seed_consent!(ctx)

    :ok =
      Enforcement.record(%{
        ctx: ctx,
        component_ref: "catalyst:local.gmail",
        event_type: :policy_consultation,
        decision: :allowed,
        consent_id: consent.id
      })

    [plain] = Arca.PolicyLog.list(org_id: ctx.org_id, project_id: ctx.project_id, limit: 1)
    refute Map.has_key?(plain, :consent)

    [joined] =
      Arca.PolicyLog.list(
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        limit: 1,
        with_consent: true
      )

    assert joined.consent.granted_by == "operator@example"
    assert joined.consent.granted_via == "interactive"
    assert joined.consent.revision == 1
    assert joined.consent.profile_kind == "owner"
    assert joined.consent.source_ref == "formula:local.audited"
  end

  test "a legacy-path row carries none of it and still records", %{ctx: ctx} do
    :ok =
      Enforcement.record(%{
        ctx: ctx,
        component_ref: "catalyst:local.legacy",
        event_type: :domain_blocked,
        decision: :denied,
        decision_reason: "domain not allowed"
      })

    [row] = Arca.PolicyLog.list(org_id: ctx.org_id, project_id: ctx.project_id, limit: 1)

    assert row.consent_id == nil
    assert row.chain == nil
    assert row.decision == "denied"

    # The join is a no-op for rows with no consent.
    [unjoined] =
      Arca.PolicyLog.list(
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        limit: 1,
        with_consent: true
      )

    refute Map.has_key?(unjoined, :consent)
  end
end
