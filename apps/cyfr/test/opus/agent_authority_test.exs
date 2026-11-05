# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AgentAuthorityTest do
  @moduledoc """
  The soul's authority, pinned as `agent:local.aqua`, runs its model
  catalyst as a child under this host: the edge selects the key bound on
  the catalyst's own profile, and the child answers the contract.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Opus.Admission
  alias Sanctum.Consent.{Bootstrap}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "agent_auth_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)
    Application.put_env(:arca, :seed_path, @seed_root)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, ctx: ctx}
  end

  test "the soul runs its model with the key bound on the model's own profile", %{ctx: ctx} do
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted and "catalyst:local.claude" in minted

    # A child inherits the grant its parent's attempt stores: the parent is
    # a real row.
    child_opts = [
      ctx: Sanctum.Context.enter_guest(ctx),
      parent_execution_id: Cyfr.Test.AttemptFixtures.lineage!(ctx).parent_execution_id,
      root_execution_id: "exec_root_#{System.unique_integer([:positive])}"
    ]

    describe = %{"operation" => "describe", "params" => %{}}

    {:ok, unbound} = Admission.authority_for(ctx, :default, @soul)
    assert unbound.source_ref == @soul

    assert {:error, {:setup_required, %{reason: "vault_selection_unbound"}}} =
             Opus.run_child(unbound, "catalyst:local.claude", nil, describe, child_opts)

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "claude key",
        kind: "api_key",
        # The provider claude's need names.
        provider_hint: "anthropic.com",
        fields: %{"ANTHROPIC_API_KEY" => "sk-test-claude"},
        # The run reads the key itself, so the entry is disclosed.
        destination: %{"hosts" => ["api.anthropic.com"]},
        disclose: true
      })

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "catalyst:local.claude"})

    decisions = %{
      ref: "catalyst:local.claude",
      bindings: [%{need: "api_key", entry_id: entry.id}]
    }

    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    {:ok, authority} = Admission.authority_for(ctx, :default, @soul)
    assert Sanctum.Consent.Loader.pinned_intact?(ctx, authority)

    # A root pin whose profile row is missing is not intact: the loader
    # fails closed rather than trusting a constructed authority.
    refute Sanctum.Consent.Loader.pinned_intact?(ctx, %{authority | profile_id: "prof_missing"})

    assert {:ok, %{output: output}} =
             Opus.run_child(
               authority,
               "catalyst:local.claude",
               nil,
               describe,
               child_opts
             )

    assert {:ok, %{"contracts" => ["model/chat@1"]}} = Prima.Model.decode_envelope(output)

    {:ok, [claude]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "catalyst:local.claude")

    :ok = Arca.ProfileStorage.transition(Sanctum.Context.actor(ctx), claude.id, :any, "revoked")
    refute Sanctum.Consent.Loader.pinned_intact?(ctx, authority)

    assert {:error, {:setup_required, %{reason: "consent_moved"}}} =
             Opus.run_child(
               authority,
               "catalyst:local.claude",
               nil,
               describe,
               child_opts
             )

    # A crew member loads as a source of its own, under the soul's policy:
    # its edge into the http hand the soul holds carries the hand's egress.
    {:ok, explorer} = Admission.authority_for(ctx, :default, "agent:local.explorer")
    assert explorer.source_ref == "agent:local.explorer"

    {:ok, http_edge} =
      Prima.Authority.Blob.lookup_edge(
        explorer.policy,
        "agent:local.explorer",
        "catalyst:local.http",
        ""
      )

    assert http_edge.egress.domains != []
  end

  test "the soul's inspection names it by its versionless ref", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)

    assert {:ok, @soul, "agent", %{"component_ref" => @soul}} =
             Admission.inspect_component(ctx, @soul)
  end

  # The soul's inspection reads no dependency tree, so its model's damage
  # first meets the run's graph.
  @tag :capture_log
  test "a model catalyst whose stored manifest does not decode is the soul's damaged " <>
         "component graph, never a setup to make",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    assert {:ok, _} = Admission.authority_for(ctx, :default, @soul)

    {count, _} =
      Ecto.Query.from(c in Arca.Schemas.Component,
        where:
          c.athanor_id == ^ctx.athanor_id and c.component_type == "catalyst" and
            c.name == "claude"
      )
      |> Arca.Repo.update_all(set: [manifest: "not json"])

    assert count > 0

    assert Admission.authority_for(ctx, :default, @soul) ==
             {:error, {:corrupt, {:component_graph, @soul}}}
  end

  test "two crew members run one catalyst with two keys, each under its own consent", %{
    ctx: ctx
  } do
    {:ok, _} = Bootstrap.run(ctx)

    # Two members the athanor made, both on claude.
    for name <- ~w(scout scribe) do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          Compendium.AquaPath.crew_file(name),
          "---\ncatalyst_ref: catalyst:local.claude\nmodel: claude-sonnet-5-5\n---\n\n#{name}\n"
        )
    end

    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    home =
      bind_claude!(ctx, name: "home key", fields: %{"ANTHROPIC_API_KEY" => "sk-home"})

    work =
      bind_claude!(ctx,
        label: "work",
        name: "work key",
        fields: %{"ANTHROPIC_API_KEY" => "sk-work"}
      )

    for {member, label} <- [{"agent:local.scout", "default"}, {"agent:local.scribe", "work"}] do
      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: member})
      decisions = %{ref: member, selections: [%{dep: "catalyst:local.claude", label: label}]}
      {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

      {:ok, _} =
        Sanctum.Consent.Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })
    end

    edge = fn member ->
      {:ok, authority} = Admission.authority_for(ctx, :default, member)

      {:ok, edge} =
        Prima.Authority.Blob.lookup_edge(authority.policy, member, "catalyst:local.claude", "")

      edge
    end

    assert edge.("agent:local.scout").vault.entry_id == home.id
    assert edge.("agent:local.scribe").vault.entry_id == work.id
  end

  defp bind_claude!(ctx, opts) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: Keyword.fetch!(opts, :name),
        kind: "api_key",
        # The provider claude's need names.
        provider_hint: "anthropic.com",
        fields: Keyword.get(opts, :fields, %{"ANTHROPIC_API_KEY" => "sk-test-claude"}),
        # The run reads the key itself, so the entry is disclosed.
        destination: %{"hosts" => ["api.anthropic.com"]},
        disclose: true
      })

    label = Keyword.get(opts, :label, "default")
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "catalyst:local.claude", label: label})

    decisions = %{
      ref: "catalyst:local.claude",
      label: label,
      bindings: [%{need: "api_key", entry_id: entry.id}]
    }

    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    entry
  end
end
