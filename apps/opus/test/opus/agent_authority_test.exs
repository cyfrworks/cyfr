# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AgentAuthorityTest do
  @moduledoc """
  The soul's authority, pinned as `agent:local.aqua`, runs its model
  catalyst as a child under this host: the edge selects the key bound on
  the catalyst's own profile, and the child answers the contract.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.{Bootstrap, Source}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "agent_auth_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
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

    {:ok, unbound} = Opus.Chain.authority_for(ctx, :default, @soul)
    assert unbound.source_ref == @soul

    assert {:error, {:setup_required, %{reason: "vault_selection_unbound"}}} =
             Opus.run_child(unbound, "catalyst:local.claude", nil, describe, child_opts)

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

    {:ok, authority} = Opus.Chain.authority_for(ctx, :default, @soul)

    assert {:ok, %{output: output}} =
             Opus.run_child(authority, "catalyst:local.claude", nil, describe, child_opts)

    assert {:ok, %{"contracts" => ["model/chat@1"]}} = Cyfr.Models.decode_envelope(output)

    # A role the soul may clone into loads as a source of its own, with its
    # edge into the http hand carrying the hand's egress.
    {:ok, web} = Opus.Chain.authority_for(ctx, :default, "agent:local.web")
    assert web.source_ref == "agent:local.web"

    {:ok, http_edge} =
      Sanctum.Authority.Blob.lookup_edge(web.policy, "agent:local.web", "catalyst:local.http", "")

    assert http_edge.egress.domains != []
  end
end
