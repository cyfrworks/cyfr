# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentSourceTest do
  @moduledoc """
  An agent is a consent source: its row projects from its file with the
  capability digest as artifact, tool actions as caps, and the model
  catalyst and hands as dependencies, never another agent; a crew member
  projects the soul's policy it runs under beside its own brain; the same
  lookups that serve component nodes serve it, its activation walks the
  closure, and only what it may do moves its digests.
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

    Cyfr.Test.SeedBundle.lay!(~w(claude gemini files http))
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

  test "the shipped tree projects the soul and every crew member as rows", %{ctx: ctx} do
    {:ok, rows} = AgentSource.rows(ctx)
    names = Enum.map(rows, & &1.name)
    assert hd(names) == "aqua"
    assert Enum.sort(names) == Enum.sort(~w(aqua claude-code codex explorer))

    soul = Enum.find(rows, &(&1.name == "aqua"))
    assert soul.component_type == "agent" and soul.publisher == "local"
    assert soul.id == @soul
    assert String.starts_with?(soul.digest, "sha256:")
    assert String.starts_with?(soul.release_digest, "sha256:")
    assert {:ok, ^soul} = Registry.get_latest(ctx, "aqua", "local", "agent")
    assert {:error, :not_found} = Registry.get_latest(ctx, "nobody", "local", "agent")
  end

  # The tree's grammar is the roster: a Markdown file whose name the path
  # grammar refuses is plain storage, and never a crew member under the
  # soul's policy.
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
    refute "bad name" in Enum.map(rows, & &1.name)
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
    assert {:ok, snap.agent} == AquaAgent.parse("aqua", bytes)

    # A crew member's snapshot keeps its own bytes and runs under the
    # soul's policy, which its capability digest names.
    {:ok, member} = Compendium.AgentIndex.snapshot(ctx, "explorer")

    {:ok, member_bytes} =
      Arca.AgentRevisions.get(Sanctum.Context.actor(ctx), member.revision_digest)

    {:ok, written} = AquaAgent.parse("explorer", member_bytes)
    assert written.tool_policy == %{}
    assert member.agent.tool_policy == snap.agent.tool_policy
    assert {:ok, member.capability_digest} == AquaAgent.capability_digest(member.agent)
  end

  test "the soul's manifest names its tools, its model and its hands, never a crew member", %{
    ctx: ctx
  } do
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")
    {:ok, agent} = AquaAgent.get(ctx, "aqua")
    manifest = soul.manifest

    tools = manifest["caps"]["tools"]
    assert "files.read" in tools and "component.list" in tools
    refute "native_search" in tools
    assert tools == Enum.sort(tools)
    assert manifest["agent"]["model"] == agent.model
    assert manifest["agent"]["catalyst"] == agent.catalyst_ref
    refute Map.has_key?(manifest, "model")

    deps = manifest["dependencies"]["static"]
    by_ref = Map.new(deps, &{&1["ref"], &1})
    assert by_ref[agent.catalyst_ref] == %{"ref" => agent.catalyst_ref}
    assert by_ref["catalyst:local.files"] == %{"ref" => "catalyst:local.files"}
    assert by_ref["catalyst:local.http"] == %{"ref" => "catalyst:local.http"}
    refute Enum.any?(deps, &String.starts_with?(&1["ref"], "agent:"))

    # A crew member's manifest: its own brain, and the soul's tools and
    # hands, under which it runs.
    {:ok, explorer} = AgentSource.latest_row(ctx, "explorer")
    assert explorer.manifest["caps"] == manifest["caps"]
    assert explorer.manifest["agent"]["policy"] == manifest["agent"]["policy"]
    assert explorer.manifest["agent"]["catalyst"] == "catalyst:local.gemini"

    hands = deps |> Enum.map(& &1["ref"]) |> List.delete(agent.catalyst_ref)

    assert explorer.manifest["dependencies"]["static"] |> Enum.map(& &1["ref"]) |> Enum.sort() ==
             Enum.sort(["catalyst:local.gemini" | hands])
  end

  test "the soul's activation walks its model and its hands, and no crew member", %{ctx: ctx} do
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")
    {:ok, live} = Activation.resolve_verified(ctx, soul)

    keys = Map.keys(live.graph) |> Enum.sort()
    assert @soul in keys
    assert Enum.filter(keys, &String.starts_with?(&1, "agent:")) == [@soul]
    assert "catalyst:local.claude" in keys
    # The explorer runs on gemini, and the soul's closure holds no crew member.
    refute "catalyst:local.gemini" in keys
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

  test "the prompt moves nothing; the soul's policy and the model move the digests", %{ctx: ctx} do
    {:ok, before} = AgentSource.latest_row(ctx, "explorer")

    write_agent!(ctx, "explorer", &%{&1 | prompt: &1.prompt <> "\n\nSay less."})
    {:ok, reworded} = AgentSource.latest_row(ctx, "explorer")
    assert reworded.digest == before.digest and reworded.release_digest == before.release_digest

    # The member runs under the soul's policy: an edit of it moves the
    # member's capability with the soul's.
    write_agent!(
      ctx,
      "aqua",
      &%{&1 | tool_policy: Map.put(&1.tool_policy, "storage.write", "ask")}
    )

    {:ok, widened} = AgentSource.latest_row(ctx, "explorer")
    refute widened.digest == before.digest
    refute widened.release_digest == before.release_digest
    assert "storage.write" in widened.manifest["caps"]["tools"]
    {:ok, soul_before} = AgentSource.latest_row(ctx, "aqua")

    # The model target is capability: retargeting is a new release.
    write_agent!(ctx, "explorer", &%{&1 | model: "another-model"})
    {:ok, retargeted} = AgentSource.latest_row(ctx, "explorer")
    refute retargeted.digest == widened.digest
    refute retargeted.release_digest == widened.release_digest

    # So are its brain's options.
    write_agent!(ctx, "explorer", &%{&1 | options: %{"effort" => "high"}})
    {:ok, tuned} = AgentSource.latest_row(ctx, "explorer")
    refute tuned.digest == retargeted.digest

    # A disabled member has no row, and the soul's row does not move with it.
    write_agent!(ctx, "explorer", &%{&1 | disabled: true})
    assert {:error, :not_found} = AgentSource.latest_row(ctx, "explorer")
    assert {:ok, ^soul_before} = AgentSource.latest_row(ctx, "aqua")
  end

  test "a glob on the soul naming a crew member is a tool pattern, not an edge into it", %{
    ctx: ctx
  } do
    write_agent!(ctx, "aqua", &%{&1 | tool_policy: Map.put(&1.tool_policy, "explorer.*", "auto")})
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")

    assert "explorer.*" in soul.manifest["caps"]["tools"]
    assert "explorer.*" in soul.manifest["agent"]["policy"]["auto"]

    refute "agent:local.explorer" in Enum.map(
             soul.manifest["dependencies"]["static"],
             & &1["ref"]
           )

    {:ok, live} = Activation.resolve_verified(ctx, soul)
    refute Map.has_key?(live.graph, "agent:local.explorer")
  end

  test "shipped_row/1 equals the tenant row while the seed files are unchanged", %{ctx: ctx} do
    for name <- ~w(aqua explorer) do
      {:ok, tenant} = AgentSource.latest_row(ctx, name)
      assert {:ok, ^tenant} = AgentSource.shipped_row(name)
    end
  end

  test "an edit of the tenant soul's policy does not change the seed rows", %{ctx: ctx} do
    {:ok, before} = AgentSource.latest_row(ctx, "explorer")

    write_agent!(
      ctx,
      "aqua",
      &%{&1 | tool_policy: Map.put(&1.tool_policy, "storage.write", "ask")}
    )

    {:ok, edited} = AgentSource.latest_row(ctx, "explorer")
    refute edited.release_digest == before.release_digest

    assert {:ok, seed} = AgentSource.shipped_row("explorer")
    assert seed.release_digest == before.release_digest
    refute seed.release_digest == edited.release_digest
  end
end
