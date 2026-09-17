# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RetainedInputTest do
  @moduledoc """
  A child run's `retained_input` rides the real path — `Cyfr.Execution`,
  admission, the worker service's runner, the record — to the payload
  store: the catalyst receives the input as sent, the store keeps the
  retained form, and the row's hash describes what was sent.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.{Bootstrap, Source}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "retained_#{System.unique_integer([:positive])}")
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
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    {:ok, ctx: ctx}
  end

  # The soul's edge selects the key bound on claude's own profile; a child
  # run needs one bound, even for a keyless `describe`.
  defp bind_claude!(ctx) do
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

    :ok
  end

  test "the store keeps the retained form of a child run's input", %{ctx: ctx} do
    :ok = bind_claude!(ctx)
    {:ok, authority} = Cyfr.Execution.authority_for(ctx, :default, @soul)
    id = Cyfr.UUID7.execution_id()

    sent = %{"operation" => "describe", "params" => %{"marker" => "SENT-ONLY"}}
    kept = %{"operation" => "describe", "params" => %{}}

    assert {:ok, _} =
             Cyfr.Execution.run_child(authority, "catalyst:local.claude", nil, sent,
               ctx: Sanctum.Context.enter_guest(ctx),
               execution_id: id,
               parent_execution_id: "exec_parent_#{System.unique_integer([:positive])}",
               root_execution_id: "exec_root_#{System.unique_integer([:positive])}",
               retained_input: kept
             )

    assert {:ok, _payload, bytes} = Arca.ExecutionPayloads.get(ctx, id, "input")
    refute bytes =~ "SENT-ONLY"
    assert Jason.decode!(bytes) == kept

    row = Arca.Repo.get!(Arca.Execution, id)
    assert row.input_hash == Arca.Execution.hash_input(sent)
  end
end
