# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.AgentConsentTest do
  @moduledoc """
  The crew consents as one source, Aqua's (`agent:local.aqua`): the fill
  mints its grant over the hands its tools name, after each shipped
  brain's own grant, and no brain and no crew member is a node of it; the shape reads Aqua's tools and
  never a member's brain, model or options, the member Aqua runs on or the
  prompt; a crew member a person makes asks nothing and leaves the grant
  alone; and the loaded authority carries the tools Aqua's list names,
  never a pattern no catalogued action matches.
  """

  use ExUnit.Case, async: false

  alias Compendium.{AquaAgent, AquaPath}
  alias Prima.Authority.Blob
  alias Sanctum.Consent.{Bootstrap, Commit, Plan, ShapeDerivation, ShapeDiff}

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

    seed = Cyfr.Test.SeedBundle.lay!(~w(claude gemini files http))

    # The seed's own crew: one member on a catalyst the soul does not run
    # on, and two on programs.
    for {name, brain} <- [
          {"explorer", [catalyst_ref: "catalyst:local.gemini", model: "gemini-pro-latest"]},
          {"claude-code", [program: "claude", model: "opus"]},
          {"openai-codex", [program: "openai-codex", model: "gpt-6.1-sol"]}
        ],
        do: :ok = Cyfr.Test.SeedBundle.member!(seed, name, brain)

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

  test "the fill mints the crew's one grant after each brain's own, and names no brain", %{
    ctx: ctx
  } do
    {:ok, %{minted: minted, skipped: skipped}} = Bootstrap.run(ctx)
    assert @soul in minted

    for brain <- ~w(catalyst:local.claude catalyst:local.gemini) do
      assert Enum.find_index(minted, &(&1 == brain)) < Enum.find_index(minted, &(&1 == @soul))
    end

    # No crew member is a source: the shipped ones, the program brains'
    # and the member Aqua runs on are neither minted nor skipped.
    sources = Enum.map(skipped, &elem(&1, 0)) ++ minted
    assert Enum.filter(sources, &String.starts_with?(&1, "agent:")) == [@soul]

    for member <- ~w(explorer claude-code openai-codex) ++ [Cyfr.Test.SeedBundle.seat_member()] do
      assert {:ok, []} =
               Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local." <> member)
    end

    {profile, head, refs} = head!(ctx, @soul)
    assert profile.label == "default" and profile.kind == :owner
    assert head.granted_via == "bootstrap"

    # No brain is a node of the grant, and it binds no key: a turn's model
    # call runs under the brain's own grant, which each shipped brain holds
    # with its own destination.
    nodes = Map.keys(Jason.decode!(head.resolved_policy)["nodes"])
    refute "catalyst:local.claude" in nodes or "catalyst:local.gemini" in nodes
    assert refs == []

    for {brain, host} <- [
          {"catalyst:local.claude", "api.anthropic.com"},
          {"catalyst:local.gemini", "generativelanguage.googleapis.com"}
        ] do
      {:ok, own} = Opus.authority_for(ctx, :default, brain)
      assert own.source_ref == brain
      assert host in own.resources.egress.domains
    end

    assert edge!(head.resolved_policy, @soul, "catalyst:local.files").storage.paths == ["data/"]

    assert Jason.decode!(head.resolved_policy)["nodes"]
           |> Map.keys()
           |> Enum.filter(&String.starts_with?(&1, "agent:")) == [@soul]

    # The grant's own ingress carries the catalog actions its list names,
    # expanded; a hand's actions are an edge, not actions.
    ingress = edge!(head.resolved_policy, @soul, "@ingress")
    assert "component.list" in ingress.tools and "aqua.list" in ingress.tools
    refute Enum.any?(ingress.tools, &String.starts_with?(&1, "files."))

    assert {:ok, %{minted: [], revised: []}} = Bootstrap.run(ctx)
  end

  test "a member's brain or model and Aqua's member ask nothing; native search " <>
         "switched, or a tool gained, is one edit and one row of the comparison",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, head, _} = head!(ctx, @soul)
    assert ShapeDerivation.live_digest(ctx, @soul) == {:ok, head.shape_digest}

    # The grant follows no member: a member's model changed and Aqua moved
    # onto another member leave the shape standing, and nothing compares
    # as changed.
    write_agent!(ctx, "explorer", &%{&1 | model: "another-model"})
    write_agent!(ctx, "aqua", &%{&1 | member: "explorer"})
    assert {:ok, %{catalyst_ref: "catalyst:local.gemini"}} = AquaAgent.get(ctx, "aqua")
    assert ShapeDerivation.live_digest(ctx, @soul) == {:ok, head.shape_digest}
    assert {:ok, []} = ShapeDiff.compute(ctx, @soul, head.resolved_policy)

    # The provider's own search is what no tool grants: the head carries
    # it on the soul's ingress, so switching it off moves both shapes and
    # compares as the one row that says so.
    assert "native_search" in edge!(head.resolved_policy, @soul, "@ingress").tools

    write_agent!(ctx, "aqua", &%{&1 | tools: List.delete(&1.tools, "native_search")})

    refute ShapeDerivation.live_digest(ctx, @soul) == {:ok, head.shape_digest}

    assert ShapeDiff.compute(ctx, @soul, head.resolved_policy) ==
             {:ok,
              [
                %{
                  node: @soul,
                  capability: "native_search",
                  change: :narrowed,
                  added: [],
                  removed: ["native_search"],
                  new: false,
                  dropped: false
                }
              ]}

    write_agent!(ctx, "aqua", &%{&1 | tools: ["native_search" | &1.tools]})

    assert ShapeDerivation.live_digest(ctx, @soul) == {:ok, head.shape_digest}

    # One tool gained is one edit and one row of the comparison.
    gained = ungranted_action(ctx)
    write_agent!(ctx, "aqua", &%{&1 | tools: [gained | &1.tools]})
    refute ShapeDerivation.live_digest(ctx, @soul) == {:ok, head.shape_digest}

    assert ShapeDiff.compute(ctx, @soul, head.resolved_policy) ==
             {:ok,
              [
                %{
                  node: @soul,
                  capability: "tools",
                  change: :widened,
                  added: [gained],
                  removed: [],
                  new: false,
                  dropped: false
                }
              ]}

    {:ok, input} = ShapeDerivation.shape_input(ctx, @soul)
    refute Map.has_key?(input, :model_target)
  end

  test "a grant narrowed to fewer tools keeps the provider's search it does not untick",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    _entry = bind_claude!(ctx)
    {_, head, _} = head!(ctx, @soul)
    tools = edge!(head.resolved_policy, @soul, "@ingress").tools
    assert "native_search" in tools and "aqua.list" in tools
    kept = tools -- ["aqua.list"]

    decisions = %{ref: @soul, subset: %{@soul => %{"tools" => kept}}}

    {:ok, plan} = Plan.plan(ctx, %{ref: @soul})
    assert {:ok, preview} = Commit.preview(ctx, decisions)

    assert {:ok, _} =
             Commit.commit(ctx, %{
               decisions: decisions,
               plan_token: plan.plan_token,
               proof: preview.proof,
               commit_digest: preview.commit_digest,
               expected_consent_revision: plan.expected_consent_revision
             })

    {_, narrowed, _} = head!(ctx, @soul)
    assert Enum.sort(edge!(narrowed.resolved_policy, @soul, "@ingress").tools) == Enum.sort(kept)
  end

  # A catalog action the soul's list does not reach, of a tool no
  # bundled catalyst serves, so granting it adds no dependency.
  defp ungranted_action(ctx) do
    {:ok, soul} = AquaAgent.get(ctx, "aqua")
    held = ShapeDerivation.expand_tools(soul.tools)

    Enum.find(Sanctum.Catalog.tool_actions(), fn key ->
      [tool, _action] = String.split(key, ".", parts: 2)

      key not in held and key not in Prima.Manifest.Caps.agent_only_tools() and
        Sanctum.VirtualTools.catalyst_for(tool) == nil
    end)
  end

  # A brain CYFR does not ship is the person's to grant, as any component
  # they install: no walk grants it, and Aqua's grant, which names no
  # brain, is minted all the same. A person's own newer release of a
  # shipped brain is theirs too.
  test "a brain CYFR does not ship, installed, is granted by no walk, and Aqua's grant is " <>
         "minted all the same",
       %{ctx: ctx} do
    Arca.Test.UnitFixtures.chat_catalyst!(ctx, "made")

    {:ok, %{minted: minted, skipped: skipped}} = Bootstrap.run(ctx)
    assert @soul in minted
    assert {"catalyst:local.made", :not_vouched} in skipped

    assert {:ok, []} =
             Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "catalyst:local.made")
  end

  test "a shipped brain whose newest release is a person's own is granted by no walk",
       %{ctx: ctx} do
    unit =
      Arca.Test.UnitFixtures.tenant_component!(ctx, "catalyst", "local", "claude", "9.0.0",
        manifest: %{
          "name" => "claude",
          "type" => "catalyst",
          "version" => "9.0.0",
          "publisher" => "local",
          "contracts" => [Prima.Model.chat_contract()]
        },
        wasm: Cyfr.Test.Guests.wasm(:catalyst)
      )

    {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)

    {:ok, %{minted: minted, skipped: skipped}} = Bootstrap.run(ctx)
    assert @soul in minted
    assert {"catalyst:local.claude", :not_vouched} in skipped
  end

  test "the shape never reads the prompt", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, soul_head, _} = head!(ctx, @soul)
    write_agent!(ctx, "aqua", &%{&1 | prompt: &1.prompt <> "\n\nBe terse."})
    assert ShapeDerivation.live_digest(ctx, @soul) == {:ok, soul_head.shape_digest}
  end

  test "a crew member a person makes asks nothing: no source, no profile, the grant alone",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, soul_head, _} = head!(ctx, @soul)

    {:ok, %{"created" => "scout"}} =
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "create", "name" => "scout"})

    write_agent!(ctx, "scout", &%{&1 | catalyst_ref: "catalyst:local.gemini", model: "m"})

    {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(ctx)
    assert {@soul, :already_bootstrapped} in skipped
    refute List.keymember?(skipped, "agent:local.scout", 0)
    assert ShapeDerivation.live_digest(ctx, @soul) == {:ok, soul_head.shape_digest}

    assert {:ok, []} =
             Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "agent:local.scout")

    {_, soul_still, _} = head!(ctx, @soul)
    assert soul_still.revision == soul_head.revision
  end

  test "a tool named as a crew member left on the soul asks for nothing: no tool, no edge into the member",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    write_agent!(ctx, "aqua", &%{&1 | tools: ["explorer.search" | &1.tools]})

    # The soul consents through the walk: it selects the key the member
    # bound on claude — a selection needs a bound lender.
    bind_claude!(ctx)
    {:ok, plan} = Plan.plan(ctx, %{ref: @soul})
    decisions = %{ref: @soul}
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
    refute Map.has_key?(Jason.decode!(head.resolved_policy)["nodes"], "agent:local.explorer")
    ingress = edge!(head.resolved_policy, @soul, "@ingress")
    assert "component.list" in ingress.tools
    refute Enum.any?(ingress.tools, &String.starts_with?(&1, "explorer."))
  end

  test "a grant whose tools moved is not re-minted", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, first, _} = head!(ctx, @soul)

    gained = ungranted_action(ctx)
    write_agent!(ctx, "aqua", &%{&1 | tools: [gained | &1.tools]})

    {:ok, %{minted: [], revised: [], skipped: skipped}} = Bootstrap.run(ctx)
    assert {@soul, :shape_moved} in skipped
    {_, still, _} = head!(ctx, @soul)
    assert still.revision == first.revision
  end

  # The seed bumps a hand Aqua's tools name (a brain is no node of the
  # grant, so its bump moves nothing here).
  test "a prose-only soul edit still re-mints under a seed bump", %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)
    {_, first, _} = head!(ctx, @soul)
    write_agent!(ctx, "aqua", &%{&1 | prompt: &1.prompt <> "\n\nBe brief."})
    Cyfr.Test.SeedBundle.isolate_from!(Application.get_env(:arca, :seed_path))

    seed_dir = Application.get_env(:arca, :seed_path)

    current =
      [seed_dir, "components", "catalysts", "local", "http", "*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> hd()

    src = Path.join([seed_dir, "components", "catalysts", "local", "http", current])
    dest = Path.join([seed_dir, "components", "catalysts", "local", "http", "9.0.0"])
    File.mkdir_p!(dest)
    File.cp!(Path.join(src, "catalyst.wasm"), Path.join(dest, "catalyst.wasm"))

    manifest =
      src
      |> Path.join("cyfr-manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("version", "9.0.0")
      |> put_in(["caps", "egress", "methods"], ["GET", "POST", "HEAD", "DELETE"])

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

  test "the soul's authority loads with its tools and no edge into a brain, whose own grant " <>
         "holds its key",
       %{ctx: ctx} do
    {:ok, _} = Bootstrap.run(ctx)

    assert {:ok, authority} = Opus.authority_for(ctx, :default, @soul)
    assert authority.source_ref == @soul
    assert "component.list" in authority.resources.tools
    assert "aqua.list" in authority.resources.tools
    refute Map.has_key?(authority.policy.nodes, "catalyst:local.claude")

    # The person binds the key on claude; claude's own grant holds it.
    entry = bind_claude!(ctx)
    {:ok, own} = Opus.authority_for(ctx, :default, "catalyst:local.claude")
    assert own.resources.vault.entry_id == entry.id

    # The revision a turn would pin is retrievable as it was.
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    soul_row = Enum.find(rows, &(&1.name == "aqua"))
    {:ok, bytes} = Arca.AgentRevisions.get(Sanctum.Context.actor(ctx), soul_row.revision_digest)
    assert {:ok, ^bytes} = Arca.get(Sanctum.Context.actor(ctx), AquaPath.soul_file())
  end
end
