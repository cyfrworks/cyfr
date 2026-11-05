# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.AgentConsentTest do
  @moduledoc """
  The athanor's agents consent as sources, each its own: the fill mints
  the shipped soul and roles with each agent's edge into its model
  selecting the model's default profile and no edge from one agent into
  another; the shape reads the model target and never the prompt; a role
  a member authors is not machine-minted — it consents through the walk
  and leaves the soul's consent alone — and the loaded authority carries
  the tools the policy names, never a pattern no catalogued action
  matches.
  """

  use ExUnit.Case, async: false

  alias Compendium.{AquaAgent, AquaPath}
  alias Prima.Authority.Blob
  alias Sanctum.Consent.{Bootstrap, Commit, Plan, ShapeDerivation}

  @soul "agent:local.aqua"

  setup tags do
    test_path =
      Path.join(System.tmp_dir!(), "agent_consent_#{System.unique_integer([:positive])}")

    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    Cyfr.Test.SeedBundle.lay!(~w(claude gemini files http))
    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    %{ctx: ctx}
  end

  defp head!(ctx, ref) do
    {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
    {:ok, row, refs} = Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile.id)
    {profile, row, refs}
  end

  defp edge!(policy, from, to) do
    {:ok, blob} = Blob.parse(policy)
    {:ok, edge} = Blob.lookup_edge(blob, from, to, "")
    edge
  end

  defp bind_claude!(ctx) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "claude key",
        kind: "api_key",
        # The provider claude's need names; the shipped claude reads its
        # key itself, so the entry is disclosed.
        provider_hint: "anthropic.com",
        fields: %{"ANTHROPIC_API_KEY" => "sk-test"},
        destination: %{"hosts" => ["api.anthropic.com"]},
        disclose: true
      })

    {:ok, plan} = Plan.plan(ctx, %{ref: "catalyst:local.claude"})

    decisions = %{
      ref: "catalyst:local.claude",
      bindings: [%{need: "api_key", entry_id: entry.id}]
    }

    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    entry
  end

  defp write_agent!(ctx, name, fun) do
    {:ok, agent} = AquaAgent.get(ctx, name)

    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        AquaPath.agent_file(name),
        AquaAgent.serialize(fun.(agent))
      )

    {:ok, _} = Compendium.AgentIndex.sync(ctx)
  end

  test "the fill mints the shipped soul and roles after their models, with their edges", %{
    ctx: ctx
  } do
    {:ok, %{minted: minted, skipped: skipped}} = Bootstrap.run(ctx)
    assert @soul in minted

    for role <- ~w(artisan builder explorer planner web),
        do: assert("agent:local.#{role}" in minted)

    assert Enum.find_index(minted, &(&1 == "catalyst:local.claude")) <
             Enum.find_index(minted, &(&1 == "agent:local.web"))

    refute Enum.any?(skipped, &match?({_, :not_vouched}, &1))

    {profile, head, refs} = head!(ctx, @soul)
    assert profile.label == "default" and profile.kind == :owner
    assert head.granted_via == "bootstrap"

    # Every selection in the graph is a binding of its own: one row each,
    # naming the label it borrows and pinning nothing, none naming an entry.
    selections =
      for {node, %{"edges" => edges}} <- Jason.decode!(head.resolved_policy)["nodes"],
          {edge_key, %{"vault" => %{"via" => via}}} <- edges,
          do: {Blob.binding_key(node, edge_key, nil), via["label"], via["binding_digest"]}

    assert {"#{@soul}|catalyst:local.claude|default", "default", nil} in selections

    assert Enum.sort(Enum.map(refs, &{&1.binding_key, &1.via_label, &1.binding_digest})) ==
             Enum.sort(selections)

    assert Enum.all?(refs, &(&1.vault_entry_id == nil and &1.share_id == nil))

    # The soul's edge into its model selects the model's default profile;
    # its edges into its hands carry the hands' own grants; no role is a
    # node of its graph.
    assert %{via: %{label: "default"}} =
             edge!(head.resolved_policy, @soul, "catalyst:local.claude").vault

    assert edge!(head.resolved_policy, @soul, "catalyst:local.files").storage.paths == ["data/"]

    assert Jason.decode!(head.resolved_policy)["nodes"]
           |> Map.keys()
           |> Enum.filter(&String.starts_with?(&1, "agent:")) == [@soul]

    assert "api.anthropic.com" in edge!(head.resolved_policy, @soul, "catalyst:local.claude").egress.domains

    # The soul's own ingress carries the catalog actions its policy names,
    # expanded; a hand's actions are an edge, not actions.
    ingress = edge!(head.resolved_policy, @soul, "@ingress")
    assert "component.list" in ingress.tools and "aqua.list" in ingress.tools
    refute Enum.any?(ingress.tools, &String.starts_with?(&1, "files."))

    # A role's edge into its own model — the explorer runs on gemini.
    {_, explorer, _} = head!(ctx, "agent:local.explorer")

    assert %{via: %{label: "default"}} =
             edge!(explorer.resolved_policy, "agent:local.explorer", "catalyst:local.gemini").vault

    assert {:ok, %{minted: [], revised: []}} = Bootstrap.run(ctx)
  end

  test "ask-to-auto and native_search move the shape; a gemini agent with files names gemini",
       %{ctx: ctx} do
    {:ok, before} = ShapeDerivation.live_digest(ctx, "agent:local.web")

    write_agent!(ctx, "web", &%{&1 | tool_policy: Map.put(&1.tool_policy, "http.get", "ask")})
    {:ok, asked} = ShapeDerivation.live_digest(ctx, "agent:local.web")
    refute asked == before

    write_agent!(ctx, "web", &%{&1 | tool_policy: Map.put(&1.tool_policy, "http.get", "auto")})
    {:ok, restored} = ShapeDerivation.live_digest(ctx, "agent:local.web")
    assert restored == before

    write_agent!(
      ctx,
      "web",
      &%{&1 | tool_policy: Map.put(&1.tool_policy, "native_search", "auto")}
    )

    {:ok, searched} = ShapeDerivation.live_digest(ctx, "agent:local.web")
    refute searched == before

    write_agent!(
      ctx,
      "explorer",
      &%{&1 | tool_policy: Map.put(&1.tool_policy, "files.read", "ask")}
    )

    {:ok, input} = ShapeDerivation.shape_input(ctx, "agent:local.explorer")
    assert input.model_target == "catalyst:local.gemini#gemini-pro-latest"
    assert "files.read" in input.tool_policy.ask
  end

  test "the shape reads the model target and never the prompt", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, head, _} = head!(ctx, "agent:local.web")
    assert ShapeDerivation.live_digest(ctx, "agent:local.web") == {:ok, head.shape_digest}

    write_agent!(ctx, "web", &%{&1 | prompt: &1.prompt <> "\n\nBe terse."})
    assert ShapeDerivation.live_digest(ctx, "agent:local.web") == {:ok, head.shape_digest}

    write_agent!(ctx, "web", &%{&1 | model: "another-model"})
    {:ok, retargeted} = ShapeDerivation.live_digest(ctx, "agent:local.web")
    refute retargeted == head.shape_digest
    {:ok, input} = ShapeDerivation.shape_input(ctx, "agent:local.web")
    assert input.model_target == "catalyst:local.claude#another-model"

    # A role's retargeting leaves the soul's shape alone: the soul holds
    # no edge into it.
    {_, soul_head, _} = head!(ctx, @soul)
    assert ShapeDerivation.live_digest(ctx, @soul) == {:ok, soul_head.shape_digest}
  end

  test "a member's role is not machine-minted, consents through the walk, and leaves the soul alone",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, soul_head, _} = head!(ctx, @soul)

    {:ok, %{"created" => "scout"}} =
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "create", "name" => "scout"})

    {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(ctx)
    assert {"agent:local.scout", :not_vouched} in skipped
    assert {@soul, :already_bootstrapped} in skipped
    assert ShapeDerivation.live_digest(ctx, @soul) == {:ok, soul_head.shape_digest}

    assert {:ok, []} =
             Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local.scout")

    # The walk: the role consents as any source does.
    {:ok, plan} = Plan.plan(ctx, %{ref: "agent:local.scout"})
    decisions = %{ref: "agent:local.scout"}
    assert {:ok, preview} = Commit.preview(ctx, decisions)

    assert {:ok, %{profile_id: profile_id}} =
             Commit.commit(ctx, %{
               decisions: decisions,
               plan_token: plan.plan_token,
               proof: preview.proof,
               commit_digest: preview.commit_digest,
               expected_consent_revision: plan.expected_consent_revision
             })

    {:ok, [scout]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local.scout")
    assert scout.id == profile_id

    {_, soul_still, _} = head!(ctx, @soul)
    assert soul_still.revision == soul_head.revision
  end

  test "a role's glob left on the soul asks for nothing: no tool, no edge into the role",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    write_agent!(ctx, "aqua", &%{&1 | tool_policy: Map.put(&1.tool_policy, "builder.*", "auto")})

    # The soul consents through the walk: it selects the key the member
    # bound on claude — a selection needs a bound lender.
    bind_claude!(ctx)
    {:ok, plan} = Plan.plan(ctx, %{ref: @soul})
    decisions = %{ref: @soul, selections: [%{dep: "catalyst:local.claude", label: "default"}]}
    assert {:ok, preview} = Commit.preview(ctx, decisions)

    assert {:ok, _} =
             Commit.commit(ctx, %{
               decisions: decisions,
               plan_token: plan.plan_token,
               proof: preview.proof,
               commit_digest: preview.commit_digest,
               expected_consent_revision: plan.expected_consent_revision
             })

    {_, head, _} = head!(ctx, @soul)
    refute Map.has_key?(Jason.decode!(head.resolved_policy)["nodes"], "agent:local.builder")
    ingress = edge!(head.resolved_policy, @soul, "@ingress")
    assert "component.list" in ingress.tools
    refute Enum.any?(ingress.tools, &String.starts_with?(&1, "builder."))
  end

  test "an edited shipped role is not re-minted", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, first, _} = head!(ctx, "agent:local.web")

    write_agent!(ctx, "web", fn agent ->
      %{agent | tool_policy: Map.put(agent.tool_policy, "files.read", "auto")}
    end)

    {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(ctx)
    assert {"agent:local.web", :shape_moved} in skipped
    {_, still, _} = head!(ctx, "agent:local.web")
    assert still.revision == first.revision

    assert {:ok, []} =
             Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local.nobody")
  end

  test "a prose-only soul edit still re-mints under a seed bump", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, first, _} = head!(ctx, @soul)
    write_agent!(ctx, "aqua", &%{&1 | prompt: &1.prompt <> "\n\nBe brief."})
    Cyfr.Test.SeedBundle.isolate_from!(Application.get_env(:arca, :seed_path))

    seed_dir = Application.get_env(:arca, :seed_path)

    current =
      [seed_dir, "components", "catalysts", "local", "claude", "*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> hd()

    src = Path.join([seed_dir, "components", "catalysts", "local", "claude", current])
    dest = Path.join([seed_dir, "components", "catalysts", "local", "claude", "9.0.0"])
    File.mkdir_p!(dest)
    File.cp!(Path.join(src, "catalyst.wasm"), Path.join(dest, "catalyst.wasm"))

    manifest =
      src
      |> Path.join("cyfr-manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("version", "9.0.0")
      |> put_in(["caps", "egress", "methods"], ["GET", "POST", "DELETE"])

    File.write!(Path.join(dest, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.rm_rf!(src)

    {:ok, _copied} = Arca.Overlay.materialize_shipped(Sanctum.Context.actor(ctx), "components")
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)

    {:ok, %{revised: revised}} = Bootstrap.run(ctx)
    assert @soul in revised
    {_, healed, _} = head!(ctx, @soul)
    assert healed.revision == first.revision + 1
    assert healed.granted_via == "bootstrap"
  end

  test "the soul's authority loads with its tools and its edge into the model", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)

    assert {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    assert authority.source_ref == @soul
    assert "component.list" in authority.resources.tools
    assert "aqua.list" in authority.resources.tools

    # Nothing is bound on claude yet: the selection stays a selection.
    {:ok, edge} = Blob.lookup_edge(authority.policy, @soul, "catalyst:local.claude", "")
    assert %{via: %{label: "default"}} = edge.vault

    # The person binds the key on claude; the soul's edge resolves to it.
    entry = bind_claude!(ctx)
    {:ok, lent} = Opus.authority_for(ctx, :default, @soul)
    {:ok, edge} = Blob.lookup_edge(lent.policy, @soul, "catalyst:local.claude", "")
    assert edge.vault.entry_id == entry.id

    # The revision a turn would pin is retrievable as it was.
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    soul_row = Enum.find(rows, &(&1.name == "aqua"))
    {:ok, bytes} = Arca.AgentRevisions.get(Sanctum.Context.actor(ctx), soul_row.revision_digest)
    assert {:ok, ^bytes} = Arca.get(Sanctum.Context.actor(ctx), AquaPath.soul_file())
  end
end
