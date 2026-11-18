# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.SeedContractTest do
  @moduledoc """
  The shipped seed, the agents' manifests and the registry agree about
  what a chat may call.

  Three lists describe one surface. The soul names what the model is
  offered (`tools`), which every crew member is offered too; each agent's
  manifest names what the consent edge grants (`caps.tools`, derived from
  that list by `Compendium.AgentSource`), which the chain authority
  checks by exact membership; the registry names what a running chain
  can reach at all (`planes`). A key on the first list and not the second
  is "Denied by chain authority" on the call; a name on the second the
  registry cannot serve is dropped silently by `expand_tools/1`, so the
  consent sheet a person signs is shorter than the manifest claims. This
  pins the three to each other, the soul's list itself, and every shipped
  member's mode.

  Hands (`files`, `storage`, `http`, `request_setup`) and the
  `native_search` gate are the loop's own and not MCP actions — they must
  not appear in caps, and are not checked against them here.
  """
  use ExUnit.Case, async: true

  alias Aqua.Hands

  @seed Path.expand("../../../../seed/aqua", __DIR__)

  # The soul's list as it ships. A tool added or dropped is a change to
  # what every member is offered, made here and in `aqua.md` together.
  @shipped_tools ~w(
    aqua.get aqua.list aqua.skill_create aqua.skill_get aqua.skill_list aqua.skill_update
    browser.click browser.close browser.key browser.open browser.page browser.read
    browser.screenshot browser.status browser.turn_off browser.type
    build.compile build.toolchains
    canvas.catalog canvas.versions canvas.write
    component.create component.inspect component.list component.pull component.search
    component.setup_plan
    crew.ask crew.list
    execution.logs execution.run
    feed.bind feed.list feed.remove
    files.delete files.edit files.grep files.list files.read files.search files.tree files.write
    http.delete http.get http.head http.links http.metadata http.options http.patch http.post
    http.put http.read
    layout.edit layout.get
    native_search
    notes.forget notes.keep notes.list notes.pin notes.read notes.search notes.workspace
    program.list program.read program.send program.start program.stop program.wait
    request_setup.open
    schedule.list
    share.list share.offered share.usage
    source.edit source.grep source.read source.tree source.write
    storage.delete storage.list storage.read
    system.status
    thread.events thread.post thread.search
    threads.list threads.read
    workspace.list workspace.open workspace.report
  )

  test "the shipped soul is offered exactly its shipped list, and every shipped member says auto" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))

    assert soul.tools == @shipped_tools
    assert length(soul.tools) == 90
    # The browser's switch is the person's alone, and an endorsement is a
    # person's act: neither is a tool any member is offered.
    refute "browser.turn_on" in soul.tools
    refute "notes.endorse" in soul.tools

    # Each file names its mode, so the shipped mode is the file's word and
    # not the parser's default.
    for agent <- seed_agents() do
      {:ok, meta, _body} =
        Compendium.AquaAgent.parse_frontmatter(File.read!(seed_file(agent.name)))

      assert meta["mode"] == "auto", agent.name
      assert agent.mode == "auto", agent.name
    end
  end

  test "the shipped soul's list names no tool the catalog lacks" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))

    # Every entry is an exact `tool.action` of a catalogued tool, a hand's
    # among them, or the provider's own search: no glob, nothing a turn
    # would drop from what it offers.
    missing =
      for key <- soul.tools,
          key != "native_search",
          {tool, action} = split(key),
          action not in Aqua.Kinds.actions_of(tool),
          do: key

    assert missing == [], "the soul names tools no catalog serves: #{inspect(missing)}"

    assert Aqua.Offered.resolve(soul.tools, {:ok, true}) |> Map.keys() |> Enum.sort() ==
             soul.tools
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
          not Sanctum.Catalog.chain_reachable?(tool, action),
          do: key

    assert refused == [], "caps grant actions a chain cannot reach: #{inspect(refused)}"
  end

  test "the manifests grant nothing the seed does not ask for" do
    asked = seed_keys() |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    unasked = Enum.reject(caps(), &MapSet.member?(asked, &1))
    assert unasked == [], "caps grant actions no shipped file names: #{inspect(unasked)}"
  end

  test "the shipped crew lists no tools: every member is offered the soul's" do
    # A crew member's file names its brain, its mode and what it is good
    # at; the tools it is offered are the soul's
    # (`Compendium.AquaAgent.under_soul/2`), so a list in a crew file
    # refuses the file.
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))
    crew = for agent <- seed_agents(), agent.name != Compendium.AquaPath.soul_name(), do: agent

    assert Enum.map(crew, & &1.name) |> Enum.sort() == ~w(claude-code explorer openai-codex)

    for member <- crew do
      assert member.tools == [], member.name
      assert Compendium.AquaAgent.under_soul(member, soul.tools).tools == @shipped_tools
      assert is_binary(member.catalyst_ref) and is_binary(member.model), member.name
      assert member.description != "" and member.avoid != "", member.name

      {:ok, meta, _body} =
        Compendium.AquaAgent.parse_frontmatter(File.read!(seed_file(member.name)))

      refute Map.has_key?(meta, "tools"), member.name
      refute Map.has_key?(meta, "tool_policy"), member.name
    end
  end

  test "the shipped soul is offered its crew, and the search gate passes through as written" do
    # The soul hands a job to a crew member with `crew.ask` and reads who
    # there is with `crew.list`; no glob stands in for them. `native_search`
    # is not a tool action and passes through `Aqua.Offered.resolve/2`
    # untouched.
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))

    offered = Aqua.Offered.resolve(soul.tools, {:ok, true})
    assert offered["crew.ask"] == "offered" and offered["crew.list"] == "offered"
    assert offered["native_search"] == "offered"
    assert Enum.filter(soul.tools, &String.ends_with?(&1, ".*")) == []
  end

  test "the shipped soul names every browser action, and the person's setting, not its list, decides whether they run" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))

    family =
      for action <- Aqua.Kinds.actions_of("browser"),
          Sanctum.Catalog.follows_setting?("browser", action),
          do: "browser." <> action

    assert length(family) == 8
    assert family -- soul.tools == []

    on = Aqua.Offered.resolve(soul.tools, {:ok, true})
    off = Aqua.Offered.resolve(soul.tools, {:ok, false})
    assert Map.take(on, family) == Map.new(family, &{&1, "offered"})
    assert Map.take(off, family) == Map.new(family, &{&1, "off"})
    assert Map.drop(on, family) == Map.drop(off, family)

    # The setting's own switch: a turn reads it and turns it off; turning
    # it on reaches no chain, so the soul is offered no such tool.
    assert ~w(browser.status browser.turn_off) -- soul.tools == []
    assert Sanctum.Catalog.chain_reachable?("browser", "turn_off")
    refute Sanctum.Catalog.chain_reachable?("browser", "turn_on")
  end

  # A grant a person signs for that no shipped prose ever exercises is a
  # line on the consent sheet for nothing. Every key of a catalogued MCP
  # action a shipped file offers is named in the body of the file that
  # holds it, or rostered here with the reason it is granted untaught.
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
    # A component's source is read and written as the builder and artisan
    # scrolls teach it, with `source(action: ...)` beside the soul's own
    # reads, and built as they teach it.
    "source.read" => "taught by the builder and artisan scrolls",
    "source.tree" => "taught by the builder and artisan scrolls",
    "source.grep" => "taught by the builder and artisan scrolls",
    "source.write" => "taught by the builder and artisan scrolls",
    "source.edit" => "taught by the builder and artisan scrolls",
    "build.compile" => "taught by the builder and artisan scrolls",
    "component.create" => "the builder and artisan scrolls' scaffold",
    # The soul's Capability Acquisition teaches these and the builder
    # scroll builds what it does not find.
    "component.list" => "capability acquisition, taught by the soul",
    "component.search" => "capability acquisition, taught by the soul",
    "component.pull" => "capability acquisition, taught by the soul",
    # A note the person asks to have forgotten; no prose teaches it.
    "notes.forget" => "a note the person asks forgotten"
  }

  test "every offered tool is taught, or rostered as granted untaught" do
    untaught =
      for {name, key} <- seed_tools(),
          mcp_action?(key),
          not Map.has_key?(@granted_but_untaught, key),
          body = seed_body(name),
          not String.contains?(body, key),
          not String.contains?(body, taught_form(key)),
          do: "#{name}: #{key}"

    assert untaught == [], Enum.join(untaught, "\n")
  end

  # A canvas is the soul's own to write: it is offered what a canvas may
  # read and the write, never the browser's activation or the way back,
  # and the scroll it follows ships beside the capability-acquisition one.
  test "the soul is offered a canvas's reads and its write, and ships the scroll" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))

    assert ~w(canvas.catalog canvas.versions canvas.write) -- soul.tools == []
    refute "canvas.activate" in soul.tools
    refute "canvas.restore" in soul.tools

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

  # The soul's list, its prompt, the canvas scroll and the artisan scroll
  # say one thing: the soul writes a canvas as a page's files, the next
  # version whole, with nobody asked; the artisan scroll teaches no canvas
  # write, and nothing teaches the module, tree or toolkit a canvas no
  # longer has.
  test "the list, the prompt, the canvas scroll and the artisan scroll agree on writing a canvas" do
    soul = File.read!(seed_file("aqua"))
    [_, section] = Regex.run(~r/^## Canvases\n(.*?)\n---/ms, soul)
    canvases = String.replace(section, ~r/\s+/, " ")
    assert canvases =~ "`canvas.write` writes the next version whole"

    body = String.replace(canvas_scroll(), ~r/\s+/, " ")
    assert body =~ "Write with `canvas.write` what the person asked for"

    artisan = File.read!(Path.join([@seed, "skills", "artisan", "SKILL.md"]))
    refute artisan =~ "| `canvas` |"
    refute artisan =~ ~r/canvas\.(write|catalog|versions)/

    for {file, text} <- [{"aqua.md", canvases}, {"skills/canvas/SKILL.md", body}] do
      refute text =~ ~r/\b(module|modules|toolkit|tree|trees|render)\b/i, file
      refute text =~ ~r/\bglass(es)?\b/i, file
      refute text =~ ~r/\bcards?\b/i, file
      refute text =~ "says yes", file
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

  # A feed is the person's: the soul is offered the list and the binding
  # and removal of one, and no press. Listing is a read, so a read-only
  # member runs it; binding is external in kind, so a read-only member
  # refuses it (`Aqua.Loop.Policy`).
  test "the soul is offered the feeds' list, binding and removal, and no press" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))

    assert ~w(feed.bind feed.list feed.remove) -- soul.tools == []
    refute "feed.press" in soul.tools
    assert Aqua.Kinds.kind_for("feed", "list") == :read
    assert Aqua.Kinds.kind_for("feed", "bind") == :external

    # The soul's grant names each exactly, which is the only way a grant
    # holds a feed write.
    assert ~w(feed.bind feed.list feed.remove) -- granted() == []
    assert seed_body("aqua") =~ "feed.list"
  end

  # The layout is the person's arrangement: the soul is offered its read
  # and its edit. The layout's write is an agent's alone and only by its
  # exact name, so the soul's own grant names both.
  test "the soul is offered the layout's read and edit, and its grant names both" do
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(seed_file("aqua")))

    assert ~w(layout.edit layout.get) -- soul.tools == []

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
      if(
        match?({:ok, _}, Sanctum.Catalog.get_tool(tool)) and
          not Sanctum.Catalog.chain_reachable?(tool, action),
        do: "is not reachable from a chain"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp granted do
    caps() |> Sanctum.Consent.ShapeDerivation.expand_tools()
  end

  # What every shipped agent's manifest grants, as one list: each agent's
  # `caps.tools` is derived from its own list.
  defp caps do
    seed_agents()
    |> Enum.flat_map(fn agent ->
      agent
      |> Compendium.AgentSource.manifest()
      |> Prima.Manifest.Caps.from_manifest(&Arca.Storage.valid_guest_path?/1)
      |> Map.fetch!(:tools)
    end)
    |> Enum.uniq()
    # The provider's own search is a tool by its name, no catalog action.
    |> Enum.reject(&(&1 == "native_search"))
    |> Enum.reject(fn key -> key |> split() |> elem(0) |> Hands.hand?() end)
  end

  # Each shipped file as it is written: the soul's list, and the crew's
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
  # not the search gate, not a tool the formula serves itself.
  defp seed_keys do
    for {name, key} <- seed_tools(), mcp_action?(key), do: {name, key}
  end

  # Every entry of every shipped file's list.
  defp seed_tools do
    for agent <- seed_agents(), key <- agent.tools, do: {agent.name, key}
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
