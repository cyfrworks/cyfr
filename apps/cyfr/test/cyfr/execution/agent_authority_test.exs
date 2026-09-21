# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.AgentAuthorityTest do
  @moduledoc """
  The soul's authority, pinned as `agent:local.aqua`, runs its model
  catalyst as a child under this host: the edge selects the key bound on
  the catalyst's own profile, and the child answers the contract.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Execution.Admission
  alias Sanctum.Consent.{Bootstrap}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, ctx: ctx}
  end

  test "the soul runs its model with the key bound on the model's own profile", %{ctx: ctx} do
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted and "catalyst:local.claude" in minted

    child_opts = [
      ctx: Sanctum.Context.enter_guest(ctx),
      parent_execution_id: "exec_parent_#{System.unique_integer([:positive])}",
      root_execution_id: "exec_root_#{System.unique_integer([:positive])}"
    ]

    describe = %{"operation" => "describe", "params" => %{}}

    {:ok, unbound} = Admission.authority_for(ctx, :default, @soul)
    assert unbound.source_ref == @soul

    assert {:error, {:setup_required, %{reason: "vault_selection_unbound"}}} =
             Cyfr.Execution.run_child(unbound, "catalyst:local.claude", nil, describe, child_opts)

    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "claude key",
        kind: "api_key",
        fields: %{"ANTHROPIC_API_KEY" => "sk-test-claude"}
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
             Cyfr.Execution.run_child(
               authority,
               "catalyst:local.claude",
               nil,
               describe,
               child_opts
             )

    assert {:ok, %{"contracts" => ["model/chat@1"]}} = Cyfr.Models.decode_envelope(output)

    {:ok, [claude]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "catalyst:local.claude")

    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), claude.id, "revoked")
    refute Sanctum.Consent.Loader.pinned_intact?(ctx, authority)

    assert {:error, {:setup_required, %{reason: "consent_moved"}}} =
             Cyfr.Execution.run_child(
               authority,
               "catalyst:local.claude",
               nil,
               describe,
               child_opts
             )

    # A role the soul may clone into loads as a source of its own, with its
    # edge into the http hand carrying the hand's egress.
    {:ok, web} = Admission.authority_for(ctx, :default, "agent:local.web")
    assert web.source_ref == "agent:local.web"

    {:ok, http_edge} =
      Cyfr.Authority.Blob.lookup_edge(web.policy, "agent:local.web", "catalyst:local.http", "")

    assert http_edge.egress.domains != []
  end

  test "two roles on the soul run one catalyst with two keys", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)

    home =
      bind_claude!(ctx, name: "home key", fields: %{"ANTHROPIC_API_KEY" => "sk-home"})

    work =
      bind_claude!(ctx,
        label: "work",
        name: "work key",
        fields: %{"ANTHROPIC_API_KEY" => "sk-work"}
      )

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: @soul})

    decisions = %{
      ref: @soul,
      selections: [
        %{from: "agent:local.web", dep: "catalyst:local.claude", label: "default"},
        %{from: "agent:local.artisan", dep: "catalyst:local.claude", label: "work"}
      ]
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

    {:ok, soul} = Admission.authority_for(ctx, :default, @soul)

    {:ok, web_edge} =
      Cyfr.Authority.Blob.lookup_edge(
        soul.policy,
        "agent:local.web",
        "catalyst:local.claude",
        ""
      )

    {:ok, artisan_edge} =
      Cyfr.Authority.Blob.lookup_edge(
        soul.policy,
        "agent:local.artisan",
        "catalyst:local.claude",
        ""
      )

    assert web_edge.vault.entry_id == home.id
    assert artisan_edge.vault.entry_id == work.id
  end

  defp bind_claude!(ctx, opts) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: Keyword.fetch!(opts, :name),
        kind: "api_key",
        fields: Keyword.get(opts, :fields, %{"ANTHROPIC_API_KEY" => "sk-test-claude"})
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
