# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.SeedContractTest do
  @moduledoc """
  The shipped seed, the agents' manifests and the registry agree about
  what a chat may call.

  Three lists describe one surface. The soul names what the
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
  not appear in caps, and are not checked here.
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

  test "nothing shipped is automatic where the kind ceiling says it asks" do
    # Kind always wins: a destructive or external action is never `auto`
    # on any agent — the soul asks for it, and a crew member holds only the soul's.
    # `Aqua.Kinds.auto_permitted?/2` is the one rule every door reads.
    automatic =
      for {name, key, "auto"} <- seed_policy(),
          {tool, action} <- exact(key),
          Aqua.Kinds.kind_for(tool, action) != nil,
          not Aqua.Kinds.auto_permitted?(tool, action),
          do: "#{name}: #{key}"

    assert automatic == [], Enum.join(automatic, "\n")
  end

  test "the shipped crew holds no policy: every member runs under the soul's" do
    # A crew member's file names its brain and what it is good at; the
    # tools it holds are the soul's (`Compendium.AquaAgent.under_soul/2`),
    # so a key in a crew file refuses the file.
    crew = for agent <- seed_agents(), agent.name != Compendium.AquaPath.soul_name(), do: agent

    assert Enum.map(crew, & &1.name) |> Enum.sort() == ~w(claude-code explorer)

    for member <- crew do
      assert member.tool_policy == %{}, member.name
      assert is_binary(member.catalyst_ref) and is_binary(member.model), member.name
      assert member.description != "" and member.avoid != "", member.name
      refute File.read!(seed_file(member.name)) =~ "tool_policy", member.name
    end
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

  test "the shipped soul asks its crew on its own, and the search gate survives composition" do
    # The soul hands a job to a crew member with `crew.ask` and reads who
    # there is with `crew.list`, both without a card; no glob stands in for
    # them. `native_search` is not a tool action and passes through
    # `Aqua.ToolGrants.effective/2` untouched.
    {:ok, soul} =
      Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    composed = Aqua.ToolGrants.resolve(soul.tool_policy, [])
    assert composed["crew.ask"] == "auto" and composed["crew.list"] == "auto"
    assert Enum.filter(Map.keys(soul.tool_policy), &String.ends_with?(&1, ".*")) == []

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
    "aqua.list" => "the roster the soul may read to describe its crew",
    "aqua.skill_get" => "taught as `aqua.skill_get`",
    "aqua.skill_list" => "the scroll index the prompt carries",
    "build.toolchains" => "the builder scroll checks toolchains before compiling",
    "component.inspect" => "read a component before building on it",
    "component.setup_plan" => "readiness check the builder and artisan scrolls run after a pull",
    "system.status" => "status checks the planner scroll answers",
    # A component's source is read as the builder and artisan scrolls
    # teach it, with `source(action: ...)` beside the soul's own reads.
    "source.read" => "taught by the builder and artisan scrolls",
    "source.tree" => "taught by the builder and artisan scrolls",
    "source.grep" => "taught by the builder and artisan scrolls",
    # The soul's Capability Acquisition teaches these and the builder
    # scroll builds what it does not find.
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

  # A canvas is the soul's own to write: it reads what a canvas may read on
  # its own and asks the person before each write, whose card names the
  # streams the version reads; the scroll it follows ships beside the
  # capability-acquisition one.
  test "the soul writes canvases: it reads on its own, asks before each write, and ships the scroll" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    assert Map.take(soul.tool_policy, ~w(canvas.catalog canvas.versions canvas.write)) == %{
             "canvas.catalog" => "auto",
             "canvas.versions" => "auto",
             "canvas.write" => "ask"
           }

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

  # The soul's policy, its prompt, the canvas scroll and the artisan scroll
  # say one thing: the soul writes a canvas as a page's files once the
  # person says yes, on a card naming the streams; the artisan scroll
  # teaches no canvas write, and nothing teaches the module, tree or
  # toolkit a canvas no longer has.
  test "the policy, the prompt, the canvas scroll and the artisan scroll agree on writing a canvas" do
    soul = File.read!(Path.join(@seed, "aqua.md"))
    [_, section] = Regex.run(~r/^## Canvases\n(.*?)\n---/ms, soul)
    canvases = String.replace(section, ~r/\s+/, " ")
    assert canvases =~ "canvas.write"
    assert canvases =~ "once the person says yes"
    assert canvases =~ "names the streams the version reads"

    body = String.replace(canvas_scroll(), ~r/\s+/, " ")
    assert body =~ "`canvas.write` asks the person first"
    assert body =~ "its card names the streams the version reads"

    artisan = File.read!(Path.join([@seed, "skills", "artisan", "SKILL.md"]))
    refute artisan =~ "| `canvas` |"
    refute artisan =~ ~r/canvas\.(write|catalog|versions)/

    for {file, text} <- [{"aqua.md", canvases}, {"skills/canvas/SKILL.md", body}] do
      refute text =~ ~r/\b(module|modules|toolkit|tree|trees|render)\b/i, file
      refute text =~ ~r/\bglass(es)?\b/i, file
    end
  end

  # The scroll's write call names exactly the arguments `canvas.write`
  # declares, its templates the operation's, and the SDK calls it teaches
  # are a canvas page's.
  test "the canvas scroll's call and SDK are the tool's and the page's" do
    body = canvas_scroll()

    [call] =
      Regex.run(~r/canvas\(action: "write", ([^)]*)\)/, body, capture: :all_but_first)

    named = ~r/(\w+): / |> Regex.scan(call, capture: :all_but_first) |> List.flatten()
    {:ok, {_provider, tool}} = Sanctum.Catalog.lookup("canvas")
    write = Enum.find(tool.operations, &(&1.action == "write"))

    assert Enum.sort(named) == Enum.sort(Enum.map(write.args, & &1.name))
    assert Enum.find(write.args, &(&1.name == "template")).enum == ~w(vanilla react)
    for template <- ~w(vanilla react), do: assert(body =~ "`#{template}`")

    for call <- ~w(cyfr.stream cyfr.on cyfr.open cyfr.press cyfr.ready),
        do: assert(body =~ "`#{call}(", call)

    # Every stream a canvas may read (one that declares a shape) is named.
    for %Prima.Provider.Stream{shape: shape, name: name} <- Sanctum.Catalog.streams(),
        not is_nil(shape),
        do: assert(body =~ "`#{name}`", name)
  end

  # `canvas.write` answers a reference pinned to the version it wrote, and
  # the layout refuses a pinned reference, so the scroll's step that adds a
  # canvas to the layout names it without its version.
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

    layout = &Prima.Layout.validate(%{"version" => 3, "canvases" => [&1]})
    assert {:ok, _} = layout.(entry)
    assert {:error, _} = layout.(%{entry | "tincture" => pinned})
  end

  # An error the page does not catch before its ready puts the standard
  # canvas in its place, so the scroll's example catches a refused open,
  # calls ready once after it, and draws what a stream carries as text.
  test "the canvas scroll's example catches a refused stream, is ready once, and draws text" do
    [example] = Regex.run(~r/```js\n(.*?)```/s, canvas_scroll(), capture: :all_but_first)
    [stream] = Regex.run(~r/cyfr\s*\.stream\("runs\.changes".*/s, example)

    assert stream =~ ".catch("
    assert [_one] = Regex.scan(~r/cyfr\.ready\(\)/, example)
    assert stream =~ ".finally(() => cyfr.ready())"
    assert example =~ "textContent"
    refute example =~ "innerHTML"
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

    # The soul's grant names each exactly, which is the only way a grant
    # holds a feed write.
    assert ~w(feed.bind feed.list feed.remove) -- granted() == []
    assert seed_body("aqua") =~ "feed.list"
  end

  # The layout is the person's arrangement: the soul reads it on its own
  # and asks before it edits it, since an edit rearranges the person's
  # screen. The layout's write is an agent's alone and only by its exact
  # name, so the soul's own grant names both.
  test "the soul reads the layout on its own and asks to edit it" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(@seed, "aqua.md")))

    assert Map.take(soul.tool_policy, ~w(layout.get layout.edit)) == %{
             "layout.get" => "auto",
             "layout.edit" => "ask"
           }

    soul_tools =
      soul
      |> Compendium.AgentSource.manifest()
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
  # `caps.tools` is derived from its own policy.
  defp caps do
    seed_agents()
    |> Enum.flat_map(fn agent ->
      agent
      |> Compendium.AgentSource.manifest()
      |> Prima.Manifest.Caps.from_manifest(&Arca.Storage.valid_guest_path?/1)
      |> Map.fetch!(:tools)
    end)
    |> Enum.uniq()
    |> Enum.reject(fn key -> key |> split() |> elem(0) |> Hands.hand?() end)
  end

  # Each shipped file as it is written: the soul's policy, and the crew's
  # none.
  defp seed_agents do
    crew = Path.join(@seed, Compendium.AquaPath.crew_dirname())

    files =
      [Path.join(@seed, "aqua.md") | Prima.Test.SourceTree.files!(Path.join(crew, "*.md"))]

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
      else: Path.join([@seed, Compendium.AquaPath.crew_dirname(), name <> ".md"])
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
