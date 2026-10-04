# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SeedModelCatalystsTest do
  @moduledoc """
  The five model catalysts the seed ships run under this host: each
  instantiates against the host's catalyst world, declares and answers
  `model/chat@1` (`describe` without a request, streaming, and a named
  model's window from its table or from the provider; a chat request off
  the contract refused before any request), links the host's
  `cyfr:emit/events`, and names its one need, `api_key`, as the
  connection of every request it makes, so CYFR attaches the key and the
  runner is never handed it. Unbound, such a request is refused before
  anything is dialled; bound to an attach-only entry, the request reaches
  CYFR's attachment as the shipped binary built it, and one outside the
  entry's destination is refused there, before anything is dialled. No
  case here reaches a provider: the shipped binary's request carried to
  its provider is not exercised.

  The versions retained beside them read their key themselves through
  `cyfr:vault/read`: their need is disclose-only, so the walk offers it
  no attach-only entry and names the update, a binding of one is refused,
  and the retained binary reached with an attach-only binding by any
  other path is refused the key as `disclosure_refused` at its read.
  """

  use ExUnit.Case, async: false

  alias Crucible.Provider
  alias Cyfr.Test.{ChatFixture, TwoServices}
  alias Prima.Manifest.Needs
  alias Sanctum.Consent.{Bootstrap, Commit, Plan}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  # Each catalyst's key field, and where a named model's window comes
  # from: a table in the binary, or the provider's API on the connection.
  @models [
    {"claude", "ANTHROPIC_API_KEY", :keyed},
    {"openai", "OPENAI_API_KEY", {:table, "gpt-5", 400_000}},
    {"gemini", "GEMINI_API_KEY", :keyed},
    {"grok", "GROK_API_KEY", {:table, "grok-4.3", 1_000_000}},
    {"openrouter", "OPENROUTER_API_KEY", :keyed}
  ]

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

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

    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  for {name, field, _window} <- @models do
    test "catalyst:local.#{name} runs under the host and names its connection", %{ctx: ctx} do
      name = unquote(name)
      field = unquote(field)
      {_name, _field, window} = List.keyfind(@models, name, 0)
      ref = "catalyst:local.#{name}"
      secret = "sk-attached-#{name}-never-handed"

      # The newest shipped version, found rather than pinned, copied in as a
      # fill copies it, then registered.
      register!(ctx, name, newest_shipped("catalysts", name))
      {:ok, %{minted: minted}} = Bootstrap.run(ctx)
      assert ref in minted

      # The manifest declares the contract, and the one need CYFR attaches:
      # by a header rule, to the hosts its egress names.
      {:ok, component} = Compendium.Registry.get_latest(ctx, name, "local", "catalyst")
      assert Prima.Model.speaks_chat?(component.manifest)
      assert [%{name: "api_key", fields: [^field], disclose: false} = need] = needs(component)
      assert %{in: "header"} = need.attach
      assert need.hosts == Enum.sort(component.manifest["caps"]["egress"]["domains"])

      # The binary answers the contract before anything is bound: `describe`
      # needs no request, and a chat request off the contract is refused as
      # such.
      assert {:ok, %{result: described}} = run(ctx, ref, "describe", %{})
      assert {:ok, capabilities} = Prima.Model.decode_envelope(described)
      assert capabilities["contracts"] == [Prima.Model.chat_contract()]
      assert capabilities["tools"] == true and capabilities["streaming"] == true
      assert is_list(capabilities["provider_tools"]) and is_list(capabilities["media_types"])

      case window do
        {:table, model, context_window} ->
          assert {:ok, %{result: answer}} = run(ctx, ref, "describe", %{"model" => model})

          assert {:ok, %{"context_window" => ^context_window}} =
                   Prima.Model.decode_envelope(answer)

          assert {:error, message} = run(ctx, ref, "describe", %{"model" => "no-such-model"})
          assert message =~ "not a model"

        :keyed ->
          # The window is the provider's, asked on the connection: with no
          # entry bound to it, CYFR refuses the request before any address
          # is resolved or anything dialled.
          assert run(ctx, ref, "describe", %{"model" => "any-model"}) ==
                   {:error, Prima.Refusal.message(:connection_not_granted)}
      end

      assert {:error, "'model' is required"} = run(ctx, ref, "chat", %{"messages" => []})

      # The operator binds an attach-only entry, admitting POST alone, to the
      # catalyst's one need.
      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "#{name} key",
          kind: "api_key",
          provider_hint: need.qualifier,
          fields: %{field => secret},
          destination: %{"hosts" => need.hosts, "methods" => ["POST"]}
        })

      consent!(ctx, ref, entry.id)

      # The model listing is a GET, which CYFR refuses outside the entry's
      # destination, before anything is dialled.
      assert run(ctx, ref, "models", %{}) ==
               {:error, Prima.Refusal.message(:destination_mismatch)}

      # Every request the binary built named the connection, went to one of
      # the need's hosts and carried no credential.
      assert [_ | _] = fetches = calls(:attached_fetch)
      assert %{"method" => "GET"} = List.last(fetches).args

      for %{args: request} <- fetches do
        assert %{"connection" => "api_key", "headers" => headers} = request
        assert URI.parse(request["url"]).host in need.hosts
        refute Enum.any?(headers, fn [header, _] -> Prima.Network.credential_header?(header) end)
      end

      # The catalyst runs to its own refusal with nothing handed to its
      # runner, and the key crossed no wire to or from it.
      assert {:error, "Unknown operation: nothing.here"} = run(ctx, ref, "nothing.here", %{})
      assert [_ | _] = attaches = calls(:attach)
      assert Enum.all?(attaches, &(&1.answer["ok"] == %{}))
      assert ChatFixture.leaks(secret, wire: TwoServices.calls()) == []
    end
  end

  test "a retained disclose-only model refuses an attach-only entry", %{ctx: ctx} do
    ref = "catalyst:local.claude"
    newest = newest_shipped("catalysts", "claude")
    [retained | _] = "catalysts" |> shipped("claude") |> Enum.reject(&(&1 == newest))
    secret = "sk-attach-only-for-a-retained-model"

    register!(ctx, "claude", retained)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert ref in minted

    {:ok, component} = Compendium.Registry.get_latest(ctx, "claude", "local", "catalyst")
    assert component.version == retained
    assert [need] = needs(component)
    assert Needs.disclose_only?(need)

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "claude key",
        kind: "api_key",
        provider_hint: need.qualifier,
        fields: %{"ANTHROPIC_API_KEY" => secret},
        destination: %{"hosts" => ["api.anthropic.com"]}
      })

    # The walk offers the retained version no attach-only entry, names the
    # newer version the media ships, and refuses a binding of one.
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})

    assert %{candidates: [], newer_shipped: ^newest} =
             Enum.find(plan.needs, &(&1.need == "api_key"))

    assert {:error, {:disclosure_refused, "api_key"}} =
             Commit.preview(ctx, %{ref: ref, bindings: [%{need: "api_key", entry_id: entry.id}]})

    # Reached with an attach-only binding by another path, here its binary
    # planted under the newest manifest, whose need attaches, the retained
    # binary's key read is refused as `disclosure_refused` rather than the
    # access denial an unbound read meets, recorded so, and the run goes on
    # to the binary's own "Failed to read" answer naming that reason.
    planted = "planted-claude"
    planted_ref = "catalyst:local.#{planted}"
    unit = Path.join([@seed_root, "components", "catalysts", "local", "claude"])

    manifest =
      Path.join([unit, newest, "cyfr-manifest.json"])
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{"name" => planted, "version" => retained})

    {:ok, _component} =
      Compendium.Registry.publish_bytes(
        ctx,
        File.read!(Path.join([unit, retained, "catalyst.wasm"])),
        %{name: planted, version: retained, type: "catalyst", manifest: Jason.encode!(manifest)}
      )

    consent!(ctx, planted_ref, entry.id)

    assert {:error, "Failed to read ANTHROPIC_API_KEY: disclosure_refused: " <> why} =
             run(ctx, planted_ref, "describe", %{"model" => "any-model"})

    assert why =~ "ANTHROPIC_API_KEY is attached to requests by CYFR and never handed to"

    assert [%{args: %{"type" => "disclosure_refused"}}] = calls(:record_denial)
    assert calls(:attached_fetch) == []
    assert ChatFixture.leaks(secret, wire: TwoServices.calls()) == []
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
    # CYFR attaches it, so the entry stays attach-only.
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "claude key",
        kind: "api_key",
        # The provider claude's need names.
        provider_hint: "anthropic.com",
        fields: %{"ANTHROPIC_API_KEY" => "sk-test-claude"},
        destination: %{"hosts" => ["api.anthropic.com"]}
      })

    consent!(ctx, "catalyst:local.claude", entry.id)

    # The assistant's authority, loaded again, lends the key on its edge;
    # the child runs to its own refusal.
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

  # Copy a shipped version in as a fill copies it, then register it.
  defp register!(ctx, name, version) do
    unit = ["components", "catalysts", "local", name, version]
    :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit)
    {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
  end

  defp needs(component), do: Needs.from_manifest(component.manifest)

  defp run(ctx, ref, operation, params) do
    Provider.handle("execution", ctx, %{
      "action" => "run",
      "reference" => ref,
      "input" => %{"operation" => operation, "params" => params}
    })
  end

  # `ref`'s owner consent, binding `entry_id` to its `api_key` need through
  # the consent walk.
  defp consent!(ctx, ref, entry_id) do
    {:ok, walk_plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: entry_id}]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: walk_plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: walk_plan.expected_consent_revision
      })
  end

  # The calls of `callback` that crossed the suite's wire in this test.
  defp calls(callback), do: for(%{callback: ^callback} = call <- TwoServices.calls(), do: call)

  defp newest_shipped(plural, name), do: hd(shipped(plural, name))

  # The versions the seed ships of `name`, newest first.
  defp shipped(plural, name) do
    Path.join(@seed_root, "components/#{plural}/local/#{name}/*")
    |> Prima.Test.SourceTree.files!()
    |> Enum.map(&Path.basename/1)
    |> Compendium.Semver.sort_desc()
  end
end
