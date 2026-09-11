# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AgentSourceTest do
  @moduledoc """
  An agent is a consent source: its row projects from its file with the
  capability digest as artifact, tool actions as caps, and the model
  catalyst, hands and clonable roles as dependencies; the same lookups
  that serve component nodes serve it, its activation walks the closure,
  and only what it may do moves its digests.
  """

  use ExUnit.Case, async: false

  alias Compendium.{Activation, AgentSource, AquaAgent, AquaPath, Registry}

  @soul "agent:local.aqua"

  setup do
    test_path = Path.join(System.tmp_dir!(), "agent_source_#{System.unique_integer([:positive])}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    Cyfr.Test.SeedBundle.lay!(~w(claude gemini files http))
    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    %{ctx: ctx}
  end

  defp write_agent!(ctx, name, fun) do
    {:ok, agent} = AquaAgent.get(ctx, name)
    :ok = Arca.put(ctx, AquaPath.agent_file(name), AquaAgent.serialize(fun.(agent)))
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
  end

  test "the shipped tree projects the soul and every role as rows", %{ctx: ctx} do
    {:ok, rows} = AgentSource.rows(ctx)
    names = Enum.map(rows, & &1.name)
    assert hd(names) == "aqua"
    assert Enum.sort(names) == Enum.sort(~w(aqua artisan builder explorer planner web))

    soul = Enum.find(rows, &(&1.name == "aqua"))
    assert soul.component_type == "agent" and soul.publisher == "local"
    assert soul.id == @soul
    assert String.starts_with?(soul.digest, "sha256:")
    assert String.starts_with?(soul.release_digest, "sha256:")
    assert {:ok, ^soul} = Registry.get_latest(ctx, "aqua", "local", "agent")
    assert {:error, :not_found} = Registry.get_latest(ctx, "nobody", "local", "agent")
    assert AgentSource.ref("web") == "agent:local.web"
    assert AgentSource.soul_ref() == @soul
    assert AgentSource.agent_ref?("agent:local.web")
    refute AgentSource.agent_ref?("catalyst:local.web")
  end

  test "snapshot keeps the bytes and parses the same ones", %{ctx: ctx} do
    {:ok, snap} = Compendium.AgentIndex.snapshot(ctx, "aqua")
    assert snap.agent.name == "aqua"
    assert String.starts_with?(snap.revision_digest, "sha256:")
    assert String.starts_with?(snap.capability_digest, "sha256:")

    {:ok, again} = Compendium.AgentIndex.snapshot(ctx, "aqua")
    assert again.revision_digest == snap.revision_digest
    assert again.capability_digest == snap.capability_digest

    {:ok, bytes} = Arca.AgentRevisions.get(ctx.athanor_id, snap.revision_digest)
    assert {:ok, ^bytes} = Arca.get(ctx, AquaPath.soul_file())
    assert {:ok, snap.agent} == AquaAgent.parse("aqua", bytes)
  end

  test "the soul's manifest names its tools, its model, its hands and its roles", %{ctx: ctx} do
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")
    {:ok, agent} = AquaAgent.get(ctx, "aqua")
    manifest = soul.manifest

    tools = manifest["caps"]["tools"]
    assert "files.read" in tools and "component.list" in tools
    refute Enum.any?(tools, &String.ends_with?(&1, "artisan.*"))
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

    for role <- ~w(artisan builder explorer planner web) do
      assert by_ref["agent:local.#{role}"] == %{
               "ref" => "agent:local.#{role}",
               "optional" => true
             }
    end

    # A role's manifest: its own model, its hands, no clone edges.
    {:ok, web} = AgentSource.latest_row(ctx, "web")

    assert web.manifest["dependencies"]["static"] |> Enum.map(& &1["ref"]) |> Enum.sort() ==
             Enum.sort([
               web.manifest |> get_in(["agent", "catalyst"]),
               "catalyst:local.http"
             ])
  end

  test "the soul's activation walks the roles, their models and the hands", %{ctx: ctx} do
    {:ok, soul} = AgentSource.latest_row(ctx, "aqua")
    {:ok, live} = Activation.resolve_verified(ctx, soul)

    keys = Map.keys(live.graph) |> Enum.sort()
    assert @soul in keys

    for role <- ~w(artisan builder explorer planner web),
        do: assert("agent:local.#{role}" in keys)

    assert "catalyst:local.claude" in keys
    # The explorer runs on gemini: its model is in the soul's closure.
    assert "catalyst:local.gemini" in keys
    assert "catalyst:local.files" in keys and "catalyst:local.http" in keys
    assert Enum.all?(live.nodes, fn {_key, node} -> node.integrity == :ok end)

    # The node keys are the blob's grammar.
    assert {:ok, _} =
             Sanctum.Authority.Blob.parse(%{
               "canonical" => "jcs-1",
               "nodes" =>
                 Map.new(keys, fn key ->
                   {key,
                    %{"limits" => Sanctum.Test.AuthorityFixtures.limits_map(), "edges" => %{}}}
                 end)
             })
  end

  test "the prompt moves nothing; the policy, the model and a disabled role move the digests", %{
    ctx: ctx
  } do
    {:ok, before} = AgentSource.latest_row(ctx, "web")
    {:ok, soul_before} = AgentSource.latest_row(ctx, "aqua")

    write_agent!(ctx, "web", &%{&1 | prompt: &1.prompt <> "\n\nSay less."})
    {:ok, reworded} = AgentSource.latest_row(ctx, "web")
    assert reworded.digest == before.digest and reworded.release_digest == before.release_digest

    write_agent!(ctx, "web", &%{&1 | tool_policy: Map.put(&1.tool_policy, "files.read", "auto")})
    {:ok, widened} = AgentSource.latest_row(ctx, "web")
    refute widened.digest == before.digest
    refute widened.release_digest == before.release_digest

    assert "catalyst:local.files" in Enum.map(
             widened.manifest["dependencies"]["static"],
             & &1["ref"]
           )

    # The model target is capability: retargeting is a new release.
    write_agent!(ctx, "web", &%{&1 | model: "another-model"})
    {:ok, retargeted} = AgentSource.latest_row(ctx, "web")
    refute retargeted.digest == widened.digest
    refute retargeted.release_digest == widened.release_digest

    write_agent!(ctx, "web", &%{&1 | disabled: true})
    assert {:error, :not_found} = AgentSource.latest_row(ctx, "web")
    {:ok, soul_after} = AgentSource.latest_row(ctx, "aqua")

    refute "agent:local.web" in Enum.map(
             soul_after.manifest["dependencies"]["static"],
             & &1["ref"]
           )

    refute soul_after.release_digest == soul_before.release_digest
    {:ok, live} = Activation.resolve_verified(ctx, soul_after)
    refute Map.has_key?(live.graph, "agent:local.web")
  end

  test "shipped_row/3 equals the tenant row while the seed file is unchanged", %{ctx: ctx} do
    {:ok, tenant} = AgentSource.latest_row(ctx, "web")
    {:ok, rows} = AgentSource.rows(ctx)
    roster = MapSet.new(rows, & &1.name)
    path = Arca.Storage.seed_prefix("aqua") ++ Enum.drop(AgentSource.unit("web"), 1)
    {:ok, bytes} = Arca.get(Sanctum.system_context(), path)
    assert {:ok, ^tenant} = AgentSource.shipped_row("web", bytes, roster)
  end

  test "a policy edit of the tenant copy does not change the seed row", %{ctx: ctx} do
    {:ok, before} = AgentSource.latest_row(ctx, "web")
    write_agent!(ctx, "web", &%{&1 | tool_policy: Map.put(&1.tool_policy, "files.read", "auto")})
    {:ok, edited} = AgentSource.latest_row(ctx, "web")
    refute edited.release_digest == before.release_digest

    {:ok, rows} = AgentSource.rows(ctx)
    roster = MapSet.new(rows, & &1.name)
    path = Arca.Storage.seed_prefix("aqua") ++ Enum.drop(AgentSource.unit("web"), 1)
    {:ok, bytes} = Arca.get(Sanctum.system_context(), path)
    assert {:ok, seed} = AgentSource.shipped_row("web", bytes, roster)
    assert seed.release_digest == before.release_digest
    refute seed.release_digest == edited.release_digest
  end
end
