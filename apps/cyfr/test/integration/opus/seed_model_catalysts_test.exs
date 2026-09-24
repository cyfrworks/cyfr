# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SeedModelCatalystsTest do
  @moduledoc """
  The five model catalysts the seed ships run under this host: each
  instantiates against the host's catalyst world, declares and answers
  `model/chat@1` (`describe` without a key, streaming, and a named
  model's window from its table or, taking the key, from the provider; a
  chat request off the contract refused before the key is read), links
  the host's `cyfr:emit/events`, reads the key its need binds
  through `cyfr:vault/read`, and answers the catalyst envelope. The
  operation asked for after the key is one no catalyst has, so the key is
  read and nothing is dialled.
  """

  use ExUnit.Case, async: false

  alias Crucible.Provider
  alias Sanctum.Consent.{Bootstrap}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  # Each catalyst's key field, and where a named model's window comes
  # from: a table in the binary, or the provider's API behind the key.
  @models [
    {"claude", "ANTHROPIC_API_KEY", :keyed},
    {"openai", "OPENAI_API_KEY", {:table, "gpt-5", 400_000}},
    {"gemini", "GEMINI_API_KEY", :keyed},
    {"grok", "GROK_API_KEY", {:table, "grok-4.3", 1_000_000}},
    {"openrouter", "OPENROUTER_API_KEY", :keyed}
  ]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "seed_models_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)
    # The real tracked bundle, served in place through the seed overlay.
    Application.put_env(:arca, :seed_path, @seed_root)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  for {name, field, _window} <- @models do
    test "catalyst:local.#{name} runs under the host and reads its bound key", %{ctx: ctx} do
      name = unquote(name)
      field = unquote(field)
      {_name, _field, window} = List.keyfind(@models, name, 0)
      ref = "catalyst:local.#{name}"

      # The newest shipped version, found rather than pinned, copied in as a
      # fill copies it, then registered.
      unit = ["components", "catalysts", "local", name, newest_shipped("catalysts", name)]
      :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit)
      {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)

      {:ok, %{minted: minted}} = Bootstrap.run(ctx)
      assert ref in minted

      # The manifest declares the contract, and the binary answers it
      # before any key exists: `describe` needs none, and a chat request
      # off the contract is refused as such rather than as a key failure.
      {:ok, component} = Compendium.Registry.get_latest(ctx, name, "local", "catalyst")
      assert Prima.Model.speaks_chat?(component.manifest)

      assert {:ok, %{result: described}} =
               Provider.handle("execution", ctx, %{
                 "action" => "run",
                 "reference" => ref,
                 "input" => %{"operation" => "describe", "params" => %{}}
               })

      assert {:ok, capabilities} = Prima.Model.decode_envelope(described)
      assert capabilities["contracts"] == [Prima.Model.chat_contract()]
      assert capabilities["tools"] == true and capabilities["streaming"] == true
      assert is_list(capabilities["provider_tools"]) and is_list(capabilities["media_types"])

      describe_model = fn model ->
        Provider.handle("execution", ctx, %{
          "action" => "run",
          "reference" => ref,
          "input" => %{"operation" => "describe", "params" => %{"model" => model}}
        })
      end

      case window do
        {:table, model, context_window} ->
          assert {:ok, %{result: answer}} = describe_model.(model)

          assert {:ok, %{"context_window" => ^context_window}} =
                   Prima.Model.decode_envelope(answer)

          assert {:error, message} = describe_model.("no-such-model")
          assert message =~ "not a model"

        :keyed ->
          assert {:error, "Failed to read " <> _} = describe_model.("any-model")
      end

      assert {:error, "'model' is required"} =
               Provider.handle("execution", ctx, %{
                 "action" => "run",
                 "reference" => ref,
                 "input" => %{"operation" => "chat", "params" => %{"messages" => []}}
               })

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
               Provider.handle("execution", ctx, %{
                 "action" => "run",
                 "reference" => ref,
                 "input" => %{"operation" => "nothing.here", "params" => %{}}
               })
    end
  end

  test "the shipped assistant runs claude with the key bound on claude's own profile", %{
    ctx: ctx
  } do
    # The soul's closure is every shipped agent's catalyst and the hands.
    for {plural, name} <- [
          {"catalysts", "claude"},
          {"catalysts", "openai"},
          {"catalysts", "gemini"},
          {"catalysts", "grok"},
          {"catalysts", "openrouter"},
          {"catalysts", "files"},
          {"catalysts", "http"}
        ] do
      unit = ["components", plural, "local", name, newest_shipped(plural, name)]
      :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit)
      {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
    end

    {:ok, _copied} = Arca.Overlay.materialize_shipped(Sanctum.Context.actor(ctx), "aqua")
    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    # The baseline consents: the soul's edge to claude selects claude's
    # default profile, which binds nothing yet.
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert "agent:local.aqua" in minted and "catalyst:local.claude" in minted

    child_opts = [
      ctx: Sanctum.Context.enter_guest(ctx),
      parent_execution_id: Cyfr.Test.AttemptFixtures.lineage!(ctx).parent_execution_id,
      root_execution_id: "exec_root_#{System.unique_integer([:positive])}"
    ]

    input = %{"operation" => "nothing.here", "params" => %{}}

    {:ok, before} = Crucible.authority_for(ctx, :default, "agent:local.aqua")

    assert {:error, {:setup_required, %{node_ref: "catalyst:local.claude:" <> _, reason: reason}}} =
             Crucible.run_child(before, "catalyst:local.claude", nil, input, child_opts)

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
    {:ok, authority} = Crucible.authority_for(ctx, :default, "agent:local.aqua")

    assert {:error, "Unknown operation: nothing.here"} =
             Crucible.run_child(authority, "catalyst:local.claude", nil, input, child_opts)

    # Revoking the catalyst's profile cuts the assistant off at the next load.
    {:ok, [claude_profile]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "catalyst:local.claude")

    :ok = Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), claude_profile.id, "revoked")
    {:ok, revoked} = Crucible.authority_for(ctx, :default, "agent:local.aqua")

    assert {:error, {:setup_required, %{reason: "vault_selection_unbound"}}} =
             Crucible.run_child(revoked, "catalyst:local.claude", nil, input, child_opts)
  end

  defp newest_shipped(plural, name) do
    Path.join(@seed_root, "components/#{plural}/local/#{name}/*")
    |> Prima.Test.SourceTree.files!()
    |> Enum.map(&Path.basename/1)
    |> Compendium.Semver.sort_desc()
    |> hd()
  end
end
