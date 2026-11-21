# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentSourceTest do
  @moduledoc """
  The crew's one grant is a consent source: Aqua's row, projected from
  its file and the athanor's brains, with its tools as caps and its hands
  and every brain the athanor can connect as dependencies, never a crew
  member or a member's brain, model or options; a crew member is no source;
  the same lookups that serve component nodes serve it, its activation
  walks the closure, and only what the crew may use moves its digests.
  """

  use ExUnit.Case, async: false

  alias Compendium.{Activation, AgentSource, AquaAgent, AquaPath, Registry}

  @soul "agent:local.aqua"

  setup tags do
    test_path = Path.join(System.tmp_dir!(), "agent_source_#{System.unique_integer([:positive])}")
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

    # A crew member of the seed's own, on another brain than the soul's.
    :ok =
      Cyfr.Test.SeedBundle.member!(seed, "explorer",
        catalyst_ref: "catalyst:local.gemini",
        model: "gemini-pro-latest"
      )

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    %{ctx: ctx}
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

  test "the tree projects the crew's grant alone, Aqua's, and no crew member", %{ctx: ctx} do
    assert {:ok, [soul]} = AgentSource.rows(ctx)
    assert soul.name == "aqua"
    assert soul.component_type == "agent" and soul.publisher == "local"
    assert soul.id == @soul
    assert String.starts_with?(soul.digest, "sha256:")
    assert String.starts_with?(soul.release_digest, "sha256:")
    assert {:ok, ^soul} = Registry.get_latest(ctx, "aqua", "local", "agent")

    # A crew member, shipped or the one Aqua runs on, is no source.
    for member <- ["explorer", Cyfr.Test.SeedBundle.seat_member(), "nobody"] do
      assert {:error, :not_found} = AgentSource.latest_row(ctx, member)
      assert {:error, :not_found} = Registry.get_latest(ctx, member, "local", "agent")
    end
  end

  # The tree's grammar is the roster: a Markdown file whose name the path
  # grammar refuses is plain storage, and never a crew member offered the
  # soul's tools.
  test "a crew file whose name the path grammar refuses is plain storage, never crew", %{
    ctx: ctx
  } do
    junk = ["aqua", "crew", "bad name.md"]
    assert AquaPath.locate(junk) == :above_unit

    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        junk,
        "---\ntitle: Bad\ncatalyst_ref: catalyst:local.claude\nmodel: m\n---\n\nbad\n"
      )

    assert {:ok, agents, errors} = AquaAgent.list(ctx)
    refute "bad name" in Enum.map(agents, & &1.name)
    assert errors == []

    {:ok, rows} = AgentSource.rows(ctx)
    assert Enum.map(rows, & &1.name) == ["aqua"]
  end

  test "snapshot keeps the bytes and parses the same ones", %{ctx: ctx} do
    {:ok, snap} = Compendium.AgentIndex.snapshot(ctx, "aqua")
    assert snap.agent.name == "aqua"
    assert String.starts_with?(snap.revision_digest, "sha256:")
    assert String.starts_with?(snap.capability_digest, "sha256:")

    {:ok, again} = Compendium.AgentIndex.snapshot(ctx, "aqua")
    assert again.revision_digest == snap.revision_digest
    assert again.capability_digest == snap.capability_digest

    {:ok, bytes} = Arca.AgentRevisions.get(Sanctum.Context.actor(ctx), snap.revision_digest)
    assert {:ok, ^bytes} = Arca.get(Sanctum.Context.actor(ctx), AquaPath.soul_file())
    # The soul as it runs: seated on the crew member its bytes name.
    assert {:ok, snap.agent} == AquaAgent.resolve(ctx, "aqua", bytes)

    # A crew member's snapshot keeps its own bytes and is offered the
    # soul's tools, which its capability digest names.
    {:ok, member} = Compendium.AgentIndex.snapshot(ctx, "explorer")

    {:ok, member_bytes} =
      Arca.AgentRevisions.get(Sanctum.Context.actor(ctx), member.revision_digest)

    {:ok, written} = AquaAgent.parse("explorer", member_bytes)
    assert written.tools == []
    assert member.agent.tools == snap.agent.tools and snap.agent.tools != []
    assert {:ok, member.capability_digest} == AquaAgent.capability_digest(member.agent)
  end

  test "the grant names Aqua's tools, its hands and every brain, never a member's model", %{
    ctx: ctx
  } do
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")
    manifest = soul.manifest

    tools = manifest["caps"]["tools"]
    assert "files.read" in tools and "component.list" in tools
    # The provider's own search, which the shipped soul turns on, is one
    # of its tools by its name.
    assert "native_search" in tools
    assert tools == Enum.sort(tools)
    refute Map.has_key?(manifest, "agent")
    refute Map.has_key?(manifest, "model")

    # Every installed catalyst that speaks the model contract is a brain
    # of the grant, the one Aqua's member runs on and the explorer's alike;
    # the hands beside them; and no crew member.
    assert {:ok, ["catalyst:local.claude", "catalyst:local.gemini"]} = AgentSource.brains(ctx)

    assert Enum.map(manifest["dependencies"]["static"], & &1["ref"]) ==
             ~w(catalyst:local.claude catalyst:local.files catalyst:local.gemini catalyst:local.http)
  end

  test "the grant's activation walks every brain and the hands, and no crew member", %{
    ctx: ctx
  } do
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")
    {:ok, live} = Activation.resolve_verified(ctx, soul)

    keys = Map.keys(live.graph) |> Enum.sort()
    assert @soul in keys
    assert Enum.filter(keys, &String.starts_with?(&1, "agent:")) == [@soul]
    assert "catalyst:local.claude" in keys and "catalyst:local.gemini" in keys
    assert "catalyst:local.files" in keys and "catalyst:local.http" in keys
    assert Enum.all?(live.nodes, fn {_key, node} -> node.integrity == :ok end)

    # The node keys are the blob's grammar.
    assert {:ok, _} =
             Prima.Authority.Blob.parse(%{
               "canonical" => "jcs-1",
               "nodes" =>
                 Map.new(keys, fn key ->
                   {key, %{"limits" => Prima.Test.AuthorityFixtures.limits_map(), "edges" => %{}}}
                 end)
             })
  end

  # The grant follows no crew member: a member's brain, model and options,
  # the member Aqua runs on and Aqua's prompt move nothing; Aqua's tools
  # move it.
  test "only Aqua's tools move the grant; a member, its brain and Aqua's seat move nothing", %{
    ctx: ctx
  } do
    {:ok, before} = AgentSource.latest_row(ctx, "aqua")

    write_agent!(ctx, "aqua", &%{&1 | prompt: &1.prompt <> "\n\nSay less."})
    write_agent!(ctx, "explorer", &%{&1 | model: "another-model", options: %{"effort" => "high"}})
    write_agent!(ctx, "explorer", &%{&1 | catalyst_ref: nil, program: "mcp_019a2b3c"})
    write_agent!(ctx, "aqua", &%{&1 | member: "explorer"})
    write_agent!(ctx, "explorer", &%{&1 | disabled: true})
    assert {:ok, ^before} = AgentSource.latest_row(ctx, "aqua")

    write_agent!(ctx, "aqua", &%{&1 | tools: ["storage.write" | &1.tools]})
    {:ok, widened} = AgentSource.latest_row(ctx, "aqua")
    refute widened.digest == before.digest
    refute widened.release_digest == before.release_digest
    assert "storage.write" in widened.manifest["caps"]["tools"]

    assert {:ok, shape} = Sanctum.Consent.ShapeDerivation.shape_input(ctx, @soul)
    refute Map.has_key?(shape, :model_target)
  end

  test "a tool on the soul named as a crew member is a tool pattern, not an edge into it", %{
    ctx: ctx
  } do
    write_agent!(ctx, "aqua", &%{&1 | tools: ["explorer.search" | &1.tools]})
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")

    assert "explorer.search" in soul.manifest["caps"]["tools"]

    refute "agent:local.explorer" in Enum.map(
             soul.manifest["dependencies"]["static"],
             & &1["ref"]
           )

    {:ok, live} = Activation.resolve_verified(ctx, soul)
    refute Map.has_key?(live.graph, "agent:local.explorer")
  end

  test "shipped_row/2 equals the tenant row while the seed's Aqua is unchanged; a member has none",
       %{ctx: ctx} do
    {:ok, tenant} = AgentSource.latest_row(ctx, "aqua")
    assert {:ok, ^tenant} = AgentSource.shipped_row(ctx, "aqua")
    assert {:error, :not_found} = AgentSource.shipped_row(ctx, "explorer")

    write_agent!(ctx, "aqua", &%{&1 | tools: ["storage.write" | &1.tools]})
    {:ok, edited} = AgentSource.latest_row(ctx, "aqua")
    assert {:ok, seed} = AgentSource.shipped_row(ctx, "aqua")
    assert seed.release_digest == tenant.release_digest
    refute seed.release_digest == edited.release_digest
  end
end
