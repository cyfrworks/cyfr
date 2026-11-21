# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AgentAuthorityTest do
  @moduledoc """
  The crew's one grant, pinned as `agent:local.aqua`, runs each brain as
  a child under this host: each brain's edge selects the key bound on that
  brain's own profile, so a turn on one brain carries that brain's key and
  destination alone, and the child answers the contract. A crew member is
  no source of its own.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Opus.Admission
  alias Sanctum.Consent.{Bootstrap}

  @soul "agent:local.aqua"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "agent_auth_#{System.unique_integer([:positive])}")
    keys = [:base_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    Cyfr.Test.SeedBundle.lay!(~w(claude gemini files http))

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

    # A crew member loads no authority of its own: it runs under the
    # crew's, whose edge into the http hand carries the hand's egress.
    assert {:error, _} = Admission.authority_for(ctx, :default, "agent:local.explorer")

    {:ok, http_edge} =
      Prima.Authority.Blob.lookup_edge(authority.policy, @soul, "catalyst:local.http", "")

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

  # Shared permission is not shared secret material: under the one grant,
  # each brain's edge lends that brain's own key to that brain's own
  # destination, so a member's call on one brain never carries another's.
  test "two brains under the one grant run each with its own brain's key, to its own host", %{
    ctx: ctx
  } do
    {:ok, _} = Bootstrap.run(ctx)
    claude = bind_claude!(ctx, name: "claude key", fields: %{"ANTHROPIC_API_KEY" => "sk-claude"})

    gemini =
      Sanctum.Test.ConsentFixtures.bind_key!(ctx, "catalyst:local.gemini", %{
        "GEMINI_API_KEY" => "g-gemini"
      })

    {:ok, authority} = Admission.authority_for(ctx, :default, @soul)

    for {brain, entry, host} <- [
          {"catalyst:local.claude", claude, "api.anthropic.com"},
          {"catalyst:local.gemini", gemini, "generativelanguage.googleapis.com"}
        ] do
      {:ok, edge} = Prima.Authority.Blob.lookup_edge(authority.policy, @soul, brain, "")
      assert edge.vault.entry_id == entry.id
      assert host in edge.egress.domains

      # The child a turn steps into on that brain holds that edge alone.
      assert {:ok, %{authority: child, bound?: true}} =
               Admission.step_invoke(authority, brain, nil, ctx: Sanctum.Context.enter_guest(ctx))

      assert child.chain == [@soul, brain]
      assert child.resources.vault.entry_id == entry.id
      assert child.resources.egress.domains == edge.egress.domains
    end
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
