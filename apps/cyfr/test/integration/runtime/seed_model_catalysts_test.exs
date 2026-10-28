# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.SeedModelCatalystsTest do
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
  """

  use ExUnit.Case, async: false

  alias Opus.Provider
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

    Sanctum.TestContext.ready!(Sanctum.TestContext.athanor_id())
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

      consent!(ctx, ref, %{entry_id: entry.id})

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

    {:ok, before} = Opus.authority_for(ctx, :default, "agent:local.aqua")

    assert {:error, {:setup_required, %{node_ref: "catalyst:local.claude:" <> _, reason: reason}}} =
             Opus.run_child(before, "catalyst:local.claude", nil, input, child_opts)

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

    consent!(ctx, "catalyst:local.claude", %{entry_id: entry.id})

    # The assistant's authority, loaded again, lends the key on its edge;
    # the child runs to its own refusal.
    {:ok, authority} = Opus.authority_for(ctx, :default, "agent:local.aqua")

    assert {:error, "Unknown operation: nothing.here"} =
             Opus.run_child(authority, "catalyst:local.claude", nil, input, child_opts)

    # Revoking the catalyst's profile cuts the assistant off at the next load.
    {:ok, [claude_profile]} =
      Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "catalyst:local.claude")

    :ok =
      Arca.ProfileStorage.transition(
        Sanctum.Context.actor(ctx),
        claude_profile.id,
        :any,
        "revoked"
      )

    {:ok, revoked} = Opus.authority_for(ctx, :default, "agent:local.aqua")

    assert {:error, {:setup_required, %{reason: "vault_selection_unbound"}}} =
             Opus.run_child(revoked, "catalyst:local.claude", nil, input, child_opts)
  end

  test "an offered instance entry whose one field is `API key` is a candidate for the Grok " <>
         "need with the map `GROK_API_KEY` to `API key`, commits with it, and attaches that " <>
         "field's value as the Bearer header",
       %{ctx: ctx} do
    ref = "catalyst:local.grok"
    secret = "xai-instance-never-handed"
    register!(ctx, "grok", newest_shipped("catalysts", "grok"))
    {person, _user} = Sanctum.TestContext.person!(ctx)

    # The instance offers everyone a key for x.ai whose one field is named
    # as a person names it, not as the catalyst reads it.
    params = %{
      name: "xai-#{System.unique_integer([:positive])}",
      kind: "api_key",
      provider_hint: "x.ai",
      fields: %{"API key" => secret},
      destination: %{"hosts" => ["api.x.ai"], "methods" => ["POST"], "paths" => ["/v1/"]},
      audience: "everyone"
    }

    confirmed =
      Sanctum.TestContext.confirmed(%{person | platform_admin: true}, :credential_entry, %{
        operation: "instance_entry.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = Sanctum.InstanceEntries.create(confirmed, params)

    # The need's one field and the entry's one field: the automatic map.
    {:ok, walk_plan} = Plan.plan(person, %{ref: ref})
    row = Enum.find(walk_plan.needs, &(&1.need == "api_key"))

    assert [candidate] =
             Enum.filter(row.candidates, &(Map.get(&1, :instance_entry_id) == entry.id))

    assert {candidate.field_names, candidate.fields} ==
             {["API key"], %{"GROK_API_KEY" => "API key"}}

    # A binding naming no map commits under the automatic one.
    consent!(person, ref, %{instance_entry_id: entry.id})

    {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(person), ref)
    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(person), profile.id)
    {:ok, blob} = Prima.Authority.Blob.parse(head.resolved_policy)
    {:ok, %{vault: vault}} = Prima.Authority.Blob.ingress(blob, ref)
    assert {vault.scope, vault.entry_id} == {"instance", entry.id}
    assert vault.projection == %{fields: %{"GROK_API_KEY" => "API key"}, scopes: []}

    # A run's request to the chat endpoint attaches the entry's `API key`
    # as the need's Bearer header.
    {:ok, component} = Compendium.Registry.get_latest(ctx, "grok", "local", "catalyst")

    facts = %{
      node_ref: "#{ref}:#{component.version}",
      activation_digest: Map.get(component, :release_digest),
      root_execution_id: "exec_root_#{System.unique_integer([:positive])}",
      profile_id: profile.id,
      consent_id: head.id
    }

    request = %{uri: URI.parse("https://api.x.ai/v1/chat/completions"), method: "POST"}

    assert {:ok, %{value: ^secret, attach: attach}} =
             Sanctum.Attach.resolve(person, vault, "api_key", request, facts)

    assert {attach.in, attach.name} == {"header", "Authorization"}
    assert Needs.render_attach(attach, secret) == "Bearer " <> secret
  end

  # Copy a shipped version in as a fill copies it, then register it.
  defp register!(ctx, name, version) do
    unit = ["components", "catalysts", "local", name, version]
    :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), unit)
    {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
  end

  defp needs(component), do: Needs.from_manifest(component.manifest)

  defp run(ctx, ref, operation, params) do
    result =
      Provider.handle("execution", ctx, %{
        "action" => "run",
        "reference" => ref,
        "input" => %{"operation" => operation, "params" => params}
      })

    TwoServices.settled!()
    result
  end

  # `ref`'s owner consent, binding the entry `identity` names
  # (`entry_id` or `instance_entry_id`) to its `api_key` need through the
  # consent walk, under the map the plan takes when the decision names none.
  defp consent!(ctx, ref, identity) do
    {:ok, walk_plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: [Map.put(identity, :need, "api_key")]}
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
