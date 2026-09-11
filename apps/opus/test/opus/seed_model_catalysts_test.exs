# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SeedModelCatalystsTest do
  @moduledoc """
  The five model catalysts the seed ships run under this host: each
  instantiates against the host's catalyst world, reads the key its need
  binds through `cyfr:vault/read`, and answers the catalyst envelope. The
  operation asked for is one no catalyst has, so the key is read and
  nothing is dialled.
  """

  use ExUnit.Case, async: false

  alias Opus.MCP
  alias Sanctum.Consent.{Bootstrap, Source}

  @seed_root Path.expand("../../../../seed", __DIR__)
  @models [
    {"claude", "ANTHROPIC_API_KEY"},
    {"openai", "OPENAI_API_KEY"},
    {"gemini", "GEMINI_API_KEY"},
    {"grok", "GROK_API_KEY"},
    {"openrouter", "OPENROUTER_API_KEY"}
  ]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "seed_models_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    # The real tracked bundle, served in place through the seed overlay.
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

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  for {name, field} <- @models do
    test "catalyst:local.#{name} runs under the host and reads its bound key", %{ctx: ctx} do
      name = unquote(name)
      field = unquote(field)
      ref = "catalyst:local.#{name}"

      # The shipped version, found rather than pinned, copied in as a fill
      # copies it, then registered.
      [version_dir] = Path.wildcard(Path.join(@seed_root, "components/catalysts/local/#{name}/*"))
      unit = ["components", "catalysts", "local", name, Path.basename(version_dir)]
      :ok = Arca.Overlay.pull_shipped(ctx, unit)
      {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)

      {:ok, %{minted: minted}} = Bootstrap.run(ctx)
      assert ref in minted

      # The operator binds a vault entry to the catalyst's one need.
      {:ok, entry} =
        Sanctum.Vault.create(ctx, %{
          name: "#{name} key",
          kind: "api_key",
          fields: %{field => "sk-test-#{name}"}
        })

      {:ok, walk_plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
      decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: entry.id}]}
      {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

      {:ok, _} =
        Sanctum.Consent.Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: walk_plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: walk_plan.expected_consent_revision
        })

      # The catalyst ran to its own refusal, which the execution tool
      # surfaces as the error: the key read succeeded first (a denied read
      # answers "Failed to read #{field}" instead), and nothing was dialled.
      assert {:error, "Unknown operation: nothing.here"} =
               MCP.handle("execution", ctx, %{
                 "action" => "run",
                 "reference" => ref,
                 "input" => %{"operation" => "nothing.here", "params" => %{}}
               })
    end
  end

  test "the shipped assistant runs claude with the key bound on claude's own profile", %{
    ctx: ctx
  } do
    for {plural, name} <- [
          {"catalysts", "claude"},
          {"catalysts", "files"},
          {"catalysts", "http"},
          {"formulas", "aqua"}
        ] do
      unit = ["components", plural, "local", name, newest_shipped(plural, name)]
      :ok = Arca.Overlay.pull_shipped(ctx, unit)
      {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
    end

    # The baseline consents: the formula's edge to claude selects claude's
    # default profile, which binds nothing yet.
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "formula:local.aqua" in minted and "catalyst:local.claude" in minted

    child_opts = [
      ctx: Sanctum.Context.enter_guest(ctx),
      parent_execution_id: "exec_parent_#{System.unique_integer([:positive])}",
      root_execution_id: "exec_root_#{System.unique_integer([:positive])}"
    ]

    input = %{"operation" => "nothing.here", "params" => %{}}

    {:ok, before} = Opus.Chain.authority_for(ctx, :default, "formula:local.aqua")

    assert {:error, {:setup_required, %{node_ref: "catalyst:local.claude:" <> _, reason: reason}}} =
             Opus.run_child(before, "catalyst:local.claude", nil, input, child_opts)

    assert reason == "vault_selection_unbound"

    # The person connects the key on the catalyst — one act, on the model.
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: "claude key",
        kind: "api_key",
        fields: %{"ANTHROPIC_API_KEY" => "sk-test-claude"}
      })

    {:ok, walk_plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "catalyst:local.claude"})

    decisions = %{
      ref: "catalyst:local.claude",
      bindings: [%{need: "api_key", entry_id: entry.id}]
    }

    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: walk_plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: walk_plan.expected_consent_revision
      })

    # The assistant's authority, loaded again, lends the key on its edge;
    # the child reads it and runs to its own refusal.
    {:ok, authority} = Opus.Chain.authority_for(ctx, :default, "formula:local.aqua")

    assert {:error, "Unknown operation: nothing.here"} =
             Opus.run_child(authority, "catalyst:local.claude", nil, input, child_opts)

    # Revoking the catalyst's profile cuts the assistant off at the next load.
    {:ok, [claude_profile]} = Source.DB.profiles(ctx, "catalyst:local.claude")
    :ok = Arca.ProfileStorage.set_status(ctx.athanor_id, claude_profile.id, "revoked")
    {:ok, revoked} = Opus.Chain.authority_for(ctx, :default, "formula:local.aqua")

    assert {:error, {:setup_required, %{reason: "vault_selection_unbound"}}} =
             Opus.run_child(revoked, "catalyst:local.claude", nil, input, child_opts)
  end

  defp newest_shipped(plural, name) do
    Path.join(@seed_root, "components/#{plural}/local/#{name}/*")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Compendium.Semver.sort_desc()
    |> hd()
  end
end
