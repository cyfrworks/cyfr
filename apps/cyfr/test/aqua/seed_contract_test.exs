# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.SeedContractTest do
  @moduledoc """
  The shipped seed, the agents' manifests and the registry agree about
  what a chat may call.

  Three lists describe one surface. The soul and each role name what the
  model may call (`tool_policy`); each agent's manifest names what the
  consent edge grants (`caps.tools`, derived from that policy by
  `Compendium.AgentSource`), which the chain authority checks by exact
  membership; the registry names what a running chain can reach at all
  (`planes`). A key on the first list and not the second is "Denied by
  chain authority" on the click; a name on the second the registry cannot
  serve is dropped silently by `expand_tools/1`, so the consent sheet a
  person signs is shorter than the manifest claims. This pins the three
  to each other.

  Hands (`files`, `storage`, `http`, `request_setup`) and the
  `native_search` gate are the loop's own and not MCP actions — they must
  not appear in caps, and are not checked here. Role globs (`builder.*`)
  are clone edges the loop resolves itself.
  """
  use ExUnit.Case, async: true

  alias Aqua.Hands

  @seed Path.expand("../../../../seed/aqua", __DIR__)

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
          not Sanctum.Catalog.chain_reachable?(tool, action),
          do: key

    assert refused == [], "caps grant actions a chain cannot reach: #{inspect(refused)}"
  end

  test "the manifests grant nothing the seed does not ask for" do
    asked = seed_keys() |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    unasked = Enum.reject(caps(), &MapSet.member?(asked, &1))
    assert unasked == [], "caps grant actions no shipped file names: #{inspect(unasked)}"
  end

  test "no role holds an action at ask — a cloned role has no card to raise" do
    # On the clone path a role's answer is a tool result the soul reads,
    # never a turn of its own, so an `ask` on it is a verb nothing can
    # fire. (A role addressed by `@mention` runs as a turn and could raise
    # a card; the shipped roles are only ever cloned, and the `aqua` door
    # refuses `ask` on any role —
    # `Compendium.AquaAgent.validate_tool_policy/2`.)
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
    # `Aqua.Kinds.auto_permitted?/2` is the one rule every door reads.
    automatic =
      for {name, key, "auto"} <- seed_policy(),
          {tool, action} <- exact(key),
          Aqua.Kinds.kind_for(tool, action) != nil,
          not Aqua.Kinds.auto_permitted?(tool, action),
          do: "#{name}: #{key}"

    assert automatic == [], Enum.join(automatic, "\n")

    destructive_on_roles =
      for {name, key, _mode} <- seed_policy(),
          name != Compendium.AquaPath.soul_name(),
          {tool, action} <- exact(key),
          Aqua.Kinds.kind_for(tool, action) in [:destructive, :external],
          do: "#{name}: #{key}"

    assert destructive_on_roles == [], Enum.join(destructive_on_roles, "\n")
  end

  test "no shipped role declares execution.run — a role launches nothing" do
    # Every launch asks and a role has no card to raise, so the key has no
    # effect on a role at any value, and the `aqua` door refuses it
    # (`Compendium.AquaAgent.validate_tool_policy/2`). The shipped soul's
    # own `execution.run` is what lets it launch, and stays.
    roles = for agent <- seed_agents(), agent.name != Compendium.AquaPath.soul_name(), do: agent

    names = Enum.map(roles, & &1.name)
    assert "artisan" in names and "builder" in names

    declaring = for role <- roles, Map.has_key?(role.tool_policy, "execution.run"), do: role.name
    assert declaring == [], "roles declaring execution.run: #{Enum.join(declaring, ", ")}"

    refused =
      for role <- roles,
          {:error, {:tool_policy_no_effect, key}} <-
            [
              Compendium.AquaAgent.validate_tool_policy(
                role.tool_policy,
                Compendium.AquaAgent.role_type()
              )
            ],
          do: "#{role.name}: #{key}"

    assert refused == [], Enum.join(refused, "\n")
  end

  test "a UI event is auto or absent, never ask" do
    asking =
      for {name, key, mode} <- seed_policy(),
          {tool, action} <- exact(key),
          Sanctum.VirtualTools.auto_only?(tool, action),
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

  # A canvas is the soul's own to write: it reads what a canvas may read
  # and writes a version without a card, and the scroll it follows ships
  # beside the capability-acquisition one.
  test "the soul writes canvases: its three canvas keys are auto, and the shipped scrolls include canvas" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    for key <- ~w(canvas.catalog canvas.versions canvas.write) do
      assert soul.tool_policy[key] == "auto", "#{key} is not auto on the soul"
    end

    roles =
      for {name, key, _mode} <- seed_policy(),
          name != Compendium.AquaPath.soul_name(),
          String.starts_with?(key, "canvas."),
          do: "#{name}: #{key}"

    assert roles == []
    refute Map.has_key?(soul.tool_policy, "canvas.activate")
    refute Map.has_key?(soul.tool_policy, "canvas.restore")

    skills = Path.join(@seed, "skills")
    assert "canvas" in File.ls!(skills)
    assert "capability-acquisition" in File.ls!(skills)

    {:ok, meta, body} =
      Compendium.AquaAgent.parse_frontmatter(
        File.read!(Path.join([skills, "canvas", "SKILL.md"]))
      )

    assert Map.keys(meta) |> Enum.sort() == ["description", "name"]
    assert meta["name"] == "canvas"
    assert is_binary(meta["description"]) and meta["description"] != ""

    for taught <- ["canvas.catalog", "feed.list", "layout.edit"], do: assert(body =~ taught)
  end

  # `canvas.write` answers a reference pinned to the version it wrote, and
  # the layout refuses a pinned reference, so the scroll's step that adds a
  # canvas to the layout names it without its version; a written canvas
  # holds only its manifest and its module, so an image it shows is a
  # `data:` URL.
  test "the canvas scroll adds a written canvas to the layout by its versionless reference" do
    body = canvas_scroll()
    [step] = Regex.run(~r/^4\. .*?(?=\n\n)/ms, body)

    assert step =~ "layout.edit"
    assert step =~ "pinned"

    # The step's own example: the canvas entry it adds is the write's
    # pinned reference with the version dropped, and the layout takes it,
    # where it refuses the pinned one.
    [pinned] = Regex.run(~r/`(tincture:[^`]+:[0-9][^`]*)`/, step, capture: :all_but_first)
    [entry] = Regex.run(~r/`(\{"id".*?\})`/, step, capture: :all_but_first)
    entry = Jason.decode!(entry)

    assert {:ok, %Prima.ComponentRef{version: version} = parsed} =
             Prima.ComponentRef.parse(pinned)

    assert is_binary(version)
    assert entry["tincture"] == Prima.ComponentRef.to_string(%{parsed | version: nil})

    layout = &Prima.Layout.validate(%{"version" => 2, "canvases" => [&1]})
    assert {:ok, _} = layout.(entry)
    assert {:error, _} = layout.(%{entry | "tincture" => pinned})

    [image] = Regex.run(~r/^- `image` .*?(?=\n- )/ms, body)
    refute image =~ "inside the version"
    assert image =~ "`data:`"
  end

  # An unhandled rejection fails a canvas into safe mode, so the scroll's
  # example catches a refused open, and takes a change once per run and
  # kind, as the seed canvas does (assets/test/canvas/canvas_skill.test.mjs
  # runs it).
  test "the canvas scroll's example catches a refused stream and takes each change once" do
    [example] = Regex.run(~r/```js\n(.*?)```/s, canvas_scroll(), capture: :all_but_first)
    [stream] = Regex.run(~r/canvas\.stream\("runs\.changes".*\n  \}\)\.catch\(/s, example)

    assert stream =~ ~s(change.execution_id + "\\n" + change.kind)
    assert stream =~ "seen.has("
  end

  defp canvas_scroll do
    {:ok, _meta, body} =
      Compendium.AquaAgent.parse_frontmatter(
        File.read!(Path.join([@seed, "skills", "canvas", "SKILL.md"]))
      )

    body
  end

  # A feed is the person's: the soul reads them on its own and asks before
  # it binds or removes one, and binding is external in kind, so no policy
  # could make it automatic.
  test "the soul lists feeds on its own and asks to bind or remove one" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    assert Map.take(soul.tool_policy, ~w(feed.list feed.bind feed.remove)) == %{
             "feed.list" => "auto",
             "feed.bind" => "ask",
             "feed.remove" => "ask"
           }

    refute Map.has_key?(soul.tool_policy, "feed.press")
    assert Aqua.Kinds.kind_for("feed", "bind") == :external
    refute Aqua.Kinds.auto_permitted?("feed", "bind")

    roles =
      for {name, key, _mode} <- seed_policy(),
          name != Compendium.AquaPath.soul_name(),
          String.starts_with?(key, "feed."),
          do: "#{name}: #{key}"

    assert roles == []

    # The soul's grant names each exactly, which is the only way a grant
    # holds a feed write.
    assert ~w(feed.bind feed.list feed.remove) -- granted() == []
    assert seed_body("aqua") =~ "feed.list"
  end

  # The layout is the person's arrangement: the soul reads it on its own
  # and asks before it edits it, since an edit rearranges the person's
  # screen. The layout's write is an agent's alone and only by its exact
  # name, so the soul's own grant names both, and no role names either.
  test "the soul reads the layout on its own and asks to edit it" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    assert Map.take(soul.tool_policy, ~w(layout.get layout.edit)) == %{
             "layout.get" => "auto",
             "layout.edit" => "ask"
           }

    roles =
      for {name, key, _mode} <- seed_policy(),
          name != Compendium.AquaPath.soul_name(),
          String.starts_with?(key, "layout."),
          do: "#{name}: #{key}"

    assert roles == []

    soul_tools =
      soul
      |> Compendium.AgentSource.manifest(MapSet.new(seed_agents(), & &1.name))
      |> Prima.Manifest.Caps.from_manifest(&Arca.Storage.valid_guest_path?/1)
      |> Map.fetch!(:tools)

    assert ~w(layout.edit layout.get) -- soul_tools == []
    assert ~w(layout.edit layout.get) -- granted() == []

    body = seed_body("aqua")
    assert body =~ "layout.get" and body =~ "layout.edit"
  end

  # ---------------------------------------------------------------------------

  defp problems(tool, action, granted) do
    key = "#{tool}.#{action}"

    [
      if(not MapSet.member?(granted, key), do: "is not in the manifest caps"),
      if(Sanctum.Catalog.in_chain_refused?(tool, action), do: "is not reachable from a chain")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp granted do
    caps() |> Sanctum.Consent.ShapeDerivation.expand_tools()
  end

  # What every shipped agent's manifest grants, as one list: each agent's
  # `caps.tools` is derived from its own policy over the roster it clones
  # into.
  defp caps do
    agents = seed_agents()
    roster = MapSet.new(agents, & &1.name)

    agents
    |> Enum.flat_map(fn agent ->
      agent
      |> Compendium.AgentSource.manifest(roster)
      |> Prima.Manifest.Caps.from_manifest(&Arca.Storage.valid_guest_path?/1)
      |> Map.fetch!(:tools)
    end)
    |> Enum.uniq()
    |> Enum.reject(fn key -> key |> split() |> elem(0) |> Hands.hand?() end)
  end

  defp seed_agents do
    roles = Path.join(@seed, Compendium.AquaPath.roles_dirname())

    files =
      [Path.join(@seed, "aqua.md") | Prima.Test.SourceTree.files!(Path.join(roles, "*.md"))]

    for path <- files,
        name = Path.basename(path, ".md"),
        {:ok, agent} = Compendium.AquaAgent.parse(name, File.read!(path)),
        do: agent
  end

  # Every `tool.action` key a shipped file holds that names an MCP action:
  # not a glob, not the search gate, not a tool the formula serves itself.
  defp seed_keys do
    for {name, key, _mode} <- seed_policy(), mcp_action?(key), do: {name, key}
  end

  # Every policy entry of every shipped file, with its mode.
  defp seed_policy do
    for agent <- seed_agents(), {key, mode} <- agent.tool_policy, do: {agent.name, key, mode}
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
      [tool, _action] -> not Hands.hand?(tool)
      _ -> false
    end
  end

  defp split(key) do
    [tool, action] = String.split(key, ".", parts: 2)
    {tool, action}
  end
end
