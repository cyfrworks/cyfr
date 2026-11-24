# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AgentAuthorityTest do
  @moduledoc """
  The crew's one grant, pinned as `agent:local.aqua`, names no brain: a
  turn's model call runs under the brain's own grant, the brain's node
  invoking itself under it as a child of the turn's root, so a call on one
  brain carries that brain's key, destination and limits alone, and the
  child answers the contract. A crew member is no source of its own.
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

    seed = Cyfr.Test.SeedBundle.lay!(~w(claude gemini files http))

    # A crew member of the seed's own, on a brain the soul does not run on.
    :ok =
      Cyfr.Test.SeedBundle.member!(seed, "explorer",
        catalyst_ref: "catalyst:local.gemini",
        model: "gemini-pro-latest"
      )

    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, ctx: ctx}
  end

  test "a brain's model call runs under the brain's own grant, the key bound on its own " <>
         "profile, as the brain invoking itself",
       %{ctx: ctx} do
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

    # Aqua's grant names no brain: a step into one from it carries nothing.
    {:ok, soul} = Admission.authority_for(ctx, :default, @soul)
    refute Map.has_key?(soul.policy.nodes, "catalyst:local.claude")

    # Until the person binds a key the brain's grant holds none: its own
    # answers about itself, which need none, run under it with nothing
    # attached.
    {:ok, unbound} = Admission.authority_for(ctx, :default, "catalyst:local.claude")
    assert unbound.source_ref == "catalyst:local.claude"
    assert unbound.resources.vault == nil

    assert {:ok, %{output: _}} =
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

    {:ok, authority} = Admission.authority_for(ctx, :default, "catalyst:local.claude")
    assert Sanctum.Consent.Loader.pinned_intact?(ctx, authority)
    assert authority.resources.vault.entry_id == entry.id

    # The call is the brain's node invoking itself: the child holds the
    # brain's own grant whole, its key, its destination and its limits.
    assert {:ok, %{authority: child, bound?: true}} =
             Admission.step_invoke(authority, "catalyst:local.claude", nil,
               ctx: Sanctum.Context.enter_guest(ctx)
             )

    assert child.chain == ["catalyst:local.claude", "catalyst:local.claude"]
    assert child.resources == authority.resources
    assert Prima.Authority.limits(child) == Prima.Authority.limits(authority)

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

    :ok = Arca.ProfileStorage.revoke_by_person(Sanctum.Context.actor(ctx), claude.id)
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
      Prima.Authority.Blob.lookup_edge(soul.policy, @soul, "catalyst:local.http", "")

    assert http_edge.egress.domains != []
  end

  test "the soul's inspection names it by its versionless ref", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)

    assert {:ok, @soul, "agent", %{"component_ref" => @soul}} =
             Admission.inspect_component(ctx, @soul)
  end

  # The soul's grant names no brain, so a brain's damage meets the brain's
  # own grant, never Aqua's.
  @tag :capture_log
  test "a model catalyst whose stored manifest does not decode is its own grant's damage, " <>
         "never Aqua's, and never a setup to make",
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

    assert {:ok, _} = Admission.authority_for(ctx, :default, @soul)

    assert {:error, {:corrupt, _damage}} =
             Admission.authority_for(ctx, :default, "catalyst:local.claude")
  end

  # Shared permission is not shared secret material: each brain's model
  # calls run under that brain's own grant, so a member's call on one
  # brain never carries another's key or reaches another's host.
  test "two brains run each under its own grant, with its own key, to its own host", %{
    ctx: ctx
  } do
    {:ok, _} = Bootstrap.run(ctx)
    claude = bind_claude!(ctx, name: "claude key", fields: %{"ANTHROPIC_API_KEY" => "sk-claude"})

    gemini =
      Sanctum.Test.ConsentFixtures.bind_key!(ctx, "catalyst:local.gemini", %{
        "GEMINI_API_KEY" => "g-gemini"
      })

    for {brain, entry, host} <- [
          {"catalyst:local.claude", claude, "api.anthropic.com"},
          {"catalyst:local.gemini", gemini, "generativelanguage.googleapis.com"}
        ] do
      {:ok, authority} = Admission.authority_for(ctx, :default, brain)
      assert Map.keys(authority.policy.nodes) == [brain]
      assert authority.resources.vault.entry_id == entry.id
      assert authority.resources.egress.domains == [host]

      # The child a turn's call steps into holds that grant alone.
      assert {:ok, %{authority: child, bound?: true}} =
               Admission.step_invoke(authority, brain, nil, ctx: Sanctum.Context.enter_guest(ctx))

      assert child.chain == [brain, brain]
      assert child.resources.vault.entry_id == entry.id
      assert child.resources.egress.domains == [host]
    end

    # A pinned profile names one brain's grant alone: claude's id never
    # loads for gemini, so a turn's pin cannot carry a call to another
    # brain's grant.
    {:ok, claude_grant} = Admission.authority_for(ctx, :default, "catalyst:local.claude")

    assert {:error, {:not_found, _id}} =
             Admission.authority_for(ctx, {:id, claude_grant.profile_id}, "catalyst:local.gemini")
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
