# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.SeedContractTest do
  @moduledoc """
  The shipped seed, the shipped manifest and the registry agree about what
  a chat may call.

  Three lists describe one surface. The soul and each role name what the
  model may call (`tool_policy`); the formula's manifest names what the
  consent edge grants (`caps.tools`), which the chain authority checks by
  exact membership; the registry names what a running chain can reach at
  all (`planes`). A key on the first list and not the second is "Denied
  by chain authority" on the click; a name on the second the registry
  cannot serve is dropped silently by `expand_tools/1`, so the consent
  sheet a person signs is shorter than the manifest claims. This pins the
  three to each other.

  Virtual tools (`files`, `storage`, `http`, `request_setup`) and the
  `native_search` gate live inside the formula and are not MCP actions —
  they must not appear in caps, and are not checked here. Role globs
  (`aqua_builder.*`) are delegation targets the formula resolves itself.
  """
  use ExUnit.Case, async: true

  alias Aqua.VirtualTools, as: AquaVirtualTools
  alias Cyfr.Ops.Catalog

  @seed Path.expand("../../../../seed/aqua", __DIR__)
  @formulas Path.expand("../../../../seed/components/formulas/local/aqua", __DIR__)

  # The `execution.*` and `schedule.*` entries come from Opus' providers;
  # an app-scoped run has no Opus modules and cannot expand them.
  @moduletag :requires_opus_modules

  test "the seed ships one formula version" do
    assert [_one] = Path.wildcard(Path.join(@formulas, "*/cyfr-manifest.json"))
  end

  test "every action the seed may call is granted by the manifest and reachable in-chain" do
    granted = MapSet.new(granted())

    failures =
      for {file, key} <- seed_keys(),
          {tool, action} = split(key),
          problem <- problems(tool, action, granted),
          do: "#{file}: #{key} #{problem}"

    assert failures == [], Enum.join(failures, "\n")
  end

  test "the manifest grants nothing the registry cannot serve" do
    caps = caps()
    granted = granted()

    dropped = caps -- granted
    assert dropped == [], "caps name actions no provider serves: #{inspect(dropped)}"
    assert length(granted) == length(caps)

    refused =
      for key <- granted,
          {tool, action} = split(key),
          not Catalog.chain_reachable?(tool, action),
          do: key

    assert refused == [], "caps grant actions a chain cannot reach: #{inspect(refused)}"
  end

  # The guest itself calls these through the registry, before any policy
  # is consulted — `tools.list` at startup to learn the catalog it filters
  # (`discover_mcp_tools`), `component.setup_plan` from
  # `dispatch_request_setup` to check a component exists before it opens
  # the setup form; the model is never offered them, so no shipped policy
  # needs to name them. The guest's `execution.run` of a wrapped catalyst is
  # NOT a registry call: the formula host intercepts it and runs the child
  # on the consent edge, so `execution.run` is in caps only because the
  # soul's policy holds it.
  @guest_calls ~w(tools.list component.setup_plan)

  test "the manifest grants nothing the seed does not ask for" do
    asked = seed_keys() |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    unasked = caps() |> Kernel.--(@guest_calls) |> Enum.reject(&MapSet.member?(asked, &1))
    assert unasked == [], "caps grant actions no shipped file names: #{inspect(unasked)}"
  end

  test "no role holds an action at ask — a cloned role has no card to raise" do
    # On the clone path a role's answer is a tool result the soul reads,
    # never a turn of its own, so an `ask` on it is a verb nothing can
    # fire. (A role addressed by `@mention` runs as a turn and could raise
    # a card; the shipped roles are only ever cloned, and the `aqua` door
    # refuses `ask` on any role — `Aqua.Policy`.)
    asking =
      for {name, key, mode} <- seed_policy(),
          name != Compendium.AquaPath.soul_name(),
          mode == "ask",
          do: "#{name}: #{key}"

    assert asking == [], Enum.join(asking, "\n")
  end

  test "nothing shipped is automatic where the kind ceiling says it asks" do
    # Kind always wins: a destructive or external action is never `auto`
    # on any agent — the soul asks for it, and a role never holds it.
    # `Aqua.Actions.auto_permitted?/2` is the one rule every door reads.
    automatic =
      for {name, key, "auto"} <- seed_policy(),
          {tool, action} <- exact(key),
          Aqua.Actions.kind_for(tool, action) != nil,
          not Aqua.Actions.auto_permitted?(tool, action),
          do: "#{name}: #{key}"

    assert automatic == [], Enum.join(automatic, "\n")

    destructive_on_roles =
      for {name, key, _mode} <- seed_policy(),
          name != Compendium.AquaPath.soul_name(),
          {tool, action} <- exact(key),
          Aqua.Actions.kind_for(tool, action) in [:destructive, :external],
          do: "#{name}: #{key}"

    assert destructive_on_roles == [], Enum.join(destructive_on_roles, "\n")
  end

  test "a UI event is auto or absent, never ask" do
    asking =
      for {name, key, mode} <- seed_policy(),
          {tool, action} <- exact(key),
          AquaVirtualTools.auto_only?(tool, action),
          mode != "auto",
          do: "#{name}: #{key}"

    assert asking == [], Enum.join(asking, "\n")
  end

  test "the shipped soul composes with its role globs and search gate intact" do
    # `Aqua.ToolGrants.effective/2` expands a catalogued tool's glob to exact
    # keys and drops the glob; a role's delegation glob and `native_search`
    # are not tool actions and must pass through untouched, or the soul's
    # clones vanish from the model's surface.
    {:ok, soul} =
      Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    composed = Aqua.ToolGrants.resolve(soul.tool_policy, [])

    for {key, mode} <- soul.tool_policy, String.ends_with?(key, ".*") do
      assert composed[key] == mode, "#{key} did not survive composition"
    end

    for {name, key, mode} <- seed_policy(), key == "native_search" do
      {:ok, agent} = Compendium.AquaAgent.parse(name, File.read!(seed_file(name)))
      assert Aqua.ToolGrants.resolve(agent.tool_policy, [])["native_search"] == mode
    end
  end

  # A grant a person signs for that no shipped prose ever exercises is a
  # line on the consent sheet for nothing. Every `auto` key of a catalogued
  # MCP action is named in the body of the file that holds it, or rostered
  # here with the reason it is granted untaught.
  @granted_but_untaught %{
    # The Working Loop's "an execution's logs", named in prose, not by key.
    "execution.logs" => "verify step of the working loop",
    # The reflex table sends the model to the Schedules page and names the list.
    "schedule.list" => "reflex table",
    # `aqua.get` serves the guides the capability-acquisition scroll cites.
    "aqua.get" => "guides read by the scroll",
    "aqua.list" => "the roster the soul may read to describe its roles",
    "aqua.skill_get" => "taught as `aqua.skill_get`",
    "aqua.skill_list" => "the scroll index the prompt carries",
    "build.toolchains" => "the builder checks toolchains before compiling",
    "component.inspect" => "read a component before building on it",
    "component.setup_plan" => "readiness check the roles run after a pull",
    "system.status" => "status checks the planner answers",
    # The soul's Capability Acquisition teaches these and hands a role the
    # components it found; a role reads no scroll of its own.
    "component.list" => "capability acquisition, taught by the soul",
    "component.search" => "capability acquisition, taught by the soul",
    "component.pull" => "capability acquisition, taught by the soul"
  }

  test "every automatic grant is taught, or rostered as granted untaught" do
    untaught =
      for {name, key, "auto"} <- seed_policy(),
          mcp_action?(key),
          not Map.has_key?(@granted_but_untaught, key),
          body = seed_body(name),
          not String.contains?(body, key),
          not String.contains?(body, taught_form(key)),
          do: "#{name}: #{key}"

    assert untaught == [], Enum.join(untaught, "\n")
  end

  # ---------------------------------------------------------------------------

  defp problems(tool, action, granted) do
    key = "#{tool}.#{action}"

    [
      if(not MapSet.member?(granted, key), do: "is not in the manifest caps"),
      if(Catalog.in_chain_refused?(tool, action), do: "is not reachable from a chain")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp granted do
    caps() |> Sanctum.Consent.ShapeDerivation.expand_tools()
  end

  defp caps do
    [path] = Path.wildcard(Path.join(@formulas, "*/cyfr-manifest.json"))
    manifest = path |> File.read!() |> Jason.decode!()
    Compendium.Manifest.Caps.from_manifest(manifest).tools
  end

  # Every `tool.action` key a shipped file holds that names an MCP action:
  # not a glob, not the search gate, not a tool the formula serves itself.
  defp seed_keys do
    for {name, key, _mode} <- seed_policy(), mcp_action?(key), do: {name, key}
  end

  # Every policy entry of every shipped file, with its mode.
  defp seed_policy do
    roles = Path.join(@seed, Compendium.AquaPath.roles_dirname())

    files =
      [Path.join(@seed, "aqua.md")] ++
        (roles
         |> File.ls!()
         |> Enum.filter(&String.ends_with?(&1, ".md"))
         |> Enum.map(&Path.join(roles, &1)))

    for path <- files,
        name = Path.basename(path, ".md"),
        {:ok, agent} = Compendium.AquaAgent.parse(name, File.read!(path)),
        {key, mode} <- agent.tool_policy,
        do: {name, key, mode}
  end

  defp exact(key) do
    case String.split(key, ".", parts: 2) do
      [_tool, "*"] -> []
      [tool, action] -> [{tool, action}]
      _ -> []
    end
  end

  defp seed_file(name) do
    if name == Compendium.AquaPath.soul_name(),
      do: Path.join(@seed, "aqua.md"),
      else: Path.join([@seed, Compendium.AquaPath.roles_dirname(), name <> ".md"])
  end

  defp seed_body(name) do
    {:ok, _meta, body} = Compendium.AquaAgent.parse_frontmatter(File.read!(seed_file(name)))
    body
  end

  # `component(action: "search")` is how a body teaches `component.search`.
  defp taught_form(key) do
    [tool, action] = String.split(key, ".", parts: 2)
    ~s(#{tool}(action: "#{action}")
  end

  defp mcp_action?("native_search"), do: false

  defp mcp_action?(key) do
    case String.split(key, ".", parts: 2) do
      [_tool, "*"] -> false
      [tool, _action] -> not AquaVirtualTools.virtual_tool?(tool)
      _ -> false
    end
  end

  defp split(key) do
    [tool, action] = String.split(key, ".", parts: 2)
    {tool, action}
  end
end
