# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DocsDriftTest do
  @moduledoc """
  Checks the README's glossary, the guides and the env examples against
  the tree and the runtime definitions they document.

  README and guide checks use tracked files and run in every checkout.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Platform.Settings.Roster
  alias Cyfr.Platform.Settings.Roster.Entry
  alias Mix.Tasks.Cyfr.Gen.ConfigurationGuide

  @repo_root Path.expand("../../../..", __DIR__)
  @readme Path.join(@repo_root, "README.md")
  @configuration_guide Path.join(@repo_root, "configuration-guide.md")

  test "README's storage tree names every tenant root and global prefix" do
    doc = File.read!(@readme)

    # The README draws the tree with a trailing slash per directory —
    # matched with the slash so a word in prose can't stand in for a root.
    for root <- Arca.Storage.tenant_roots() ++ Arca.Storage.global_prefixes() do
      assert doc =~ root <> "/",
             "root #{root}/ is missing from README's storage tree"
    end
  end

  # The glossary names each part once, with the environment prefixes it
  # owns. The prefixes are this roster, each named by one row.
  @env_prefixes ~w(CYFR_ CYFR_OPUS_ CYFR_HOST_API_ CYFR_LOCUS_RUNTIME_ CYFR_LOCUS_BUILDS_
                   CYFR_LOCUS_BACKENDS_ LOCUS_RUNTIME_ LOCUS_BUILDS_ LOCUS_BACKENDS_ LOCUS_LOG_
                   KEEPER_ RUNTIME_)
  @glossary_names ~w(Prima Arca Sanctum Cyfr Compendium Aqua Opus Emissary Prism Codex Locus
                     actor athanor)

  # The files that read the releases' environment: the control plane's
  # configuration (the `CYFR_*` variables `config/runtime.exs` reads into
  # the operator keys of `Cyfr.Boundaries.config_key_classes/0`, the
  # resolvers it calls, and the platform settings roster whose variables it
  # reads), the Locus release's one reader, `Locus.Config`, whose roster
  # holds every role's names (the runtime's `LOCUS_RUNTIME_*` and its
  # runners' `RUNTIME_*` among them), and the keeper's own sources
  # (`keeper_sources/0`).
  @env_readers ~w(config/runtime.exs apps/cyfr/lib/cyfr/runtime_config.ex
                  apps/cyfr/lib/cyfr/platform/settings/roster.ex
                  apps/locus/lib/locus/config.ex)

  # The names the roster spells that no release reads: those other
  # programs own (`Roster.foreign/0`), which their owners document, and
  # those compose reads alone (`Roster.compose_only/0`).
  defp spelled_not_read do
    MapSet.new(Enum.map(Roster.foreign(), &elem(&1, 0)) ++ Roster.compose_only())
  end

  # The keeper's Go sources other than its tests, relative to the root.
  defp keeper_sources do
    @repo_root
    |> Path.join("apps/locus/keeper/**/*.go")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "_test.go"))
    |> Enum.map(&Path.relative_to(&1, @repo_root))
  end

  defp glossary do
    [_, section] = Regex.run(~r/^## Glossary\n(.*?)(?=^## )/ms, File.read!(@readme))

    [header, _rule | rows] =
      for line <- String.split(section, "\n"),
          String.starts_with?(line, "|"),
          do: line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

    {header, rows}
  end

  # The backquoted names in one column of the glossary, every row's.
  defp glossary_column(title, pattern \\ ~r/`([^`]+)`/) do
    {header, rows} = glossary()
    column = Enum.find_index(header, &(&1 == title))
    assert column, "the glossary has no #{title} column"

    for row <- rows,
        captures <- Regex.scan(pattern, Enum.at(row, column), capture: :all_but_first),
        name <- captures,
        name != "",
        do: name
  end

  test "README's glossary names every part, and its prefix column is the environment roster" do
    {header, rows} = glossary()

    assert Enum.all?(rows, &(length(&1) == length(header))), "a glossary row has the wrong width"

    names = Enum.map(rows, &hd/1)

    for name <- @glossary_names do
      assert name in names, "the glossary has no row for #{name}"
    end

    column = Enum.find_index(header, &(&1 == "Environment prefix"))
    assert column, "the glossary has no environment prefix column"

    prefixes =
      for row <- rows,
          [prefix] <-
            Regex.scan(~r/`([A-Z][A-Z0-9_]*)`/, Enum.at(row, column), capture: :all_but_first),
          do: prefix

    assert Enum.sort(prefixes) == Enum.sort(@env_prefixes),
           "the glossary's environment prefixes #{inspect(prefixes)} are not the roster " <>
             "#{inspect(@env_prefixes)}, each once"
  end

  # ARCHITECTURE.md owns what each part is responsible for and the glossary
  # names the same parts, so the two cannot describe different sets.
  @architecture Path.join(@repo_root, "ARCHITECTURE.md")
  @part_names @glossary_names -- ~w(actor athanor)

  test "ARCHITECTURE.md describes exactly the parts the glossary names" do
    described =
      Regex.scan(~r/^### (\w+)(?: \([^)]*\))?: /m, File.read!(@architecture),
        capture: :all_but_first
      )
      |> List.flatten()

    assert Enum.sort(described) == Enum.sort(@part_names),
           "ARCHITECTURE.md's module sections #{inspect(described)} are not the glossary's " <>
             "parts #{inspect(@part_names)}"
  end

  test "ARCHITECTURE.md's four ports are the port roster" do
    [section] =
      Regex.run(~r/^### 4\.2 The four ports\n(.*?)(?=^### )/ms, File.read!(@architecture),
        capture: :all_but_first
      )

    # Each row's upward need, as the roster words what the port carries.
    documented =
      for line <- String.split(section, "\n"),
          String.starts_with?(line, "| "),
          [need, behaviour] <-
            Regex.scan(~r/^\| ([^|]*?) \(`([A-Za-z.]+)`\)/, line, capture: :all_but_first),
          do: {behaviour, need}

    rostered =
      Enum.map(Cyfr.Boundaries.ports(), fn port ->
        {first, rest} = String.split_at(port.what, 1)
        {port.behaviour, String.upcase(first) <> rest}
      end)

    assert length(documented) == 4

    assert Enum.sort(documented) == Enum.sort(rostered),
           "ARCHITECTURE.md documents the ports #{inspect(documented)}; " <>
             "Cyfr.Boundaries.ports/0 rosters #{inspect(rostered)}"
  end

  defp read_variables do
    not_read = spelled_not_read()

    for file <- @env_readers ++ keeper_sources(),
        [name] <-
          Regex.scan(
            ~r/"((?:CYFR|LOCUS|KEEPER|RUNTIME)_[A-Z0-9_]*[A-Z0-9])"/,
            File.read!(Path.join(@repo_root, file)),
            capture: :all_but_first
          ),
        not MapSet.member?(not_read, name),
        uniq: true,
        do: name
  end

  # A variable belongs to the longest prefix of the roster it begins with.
  defp owning_prefix(variable) do
    @env_prefixes
    |> Enum.filter(&String.starts_with?(variable, &1))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  test "the environment prefixes are the ones the releases' readers name, each in use" do
    read = read_variables()

    # Guards against the scan quietly matching nothing.
    assert "CYFR_LOCUS_BACKENDS_KEY" in read and "LOCUS_BACKENDS_KEY" in read
    assert "LOCUS_RUNTIME_KEY" in read and "KEEPER_CHANNEL" in read
    assert length(read) >= 100, "the scan found only #{length(read)} variables"

    unowned = Enum.filter(read, &is_nil(owning_prefix(&1)))

    assert unowned == [],
           "these variables are read under a prefix the glossary does not name: " <>
             inspect(unowned)

    unused = @env_prefixes -- Enum.map(read, &owning_prefix/1)

    assert unused == [],
           "the glossary names these prefixes, and no reader reads a variable under them: " <>
             inspect(unused)
  end

  # The scans tell this repository's modules from the rest by their root
  # namespace: each capitalised part the glossary gives a directory, and
  # the web tier of each part whose directory has one.
  test "the boundary catalog's product roots are the glossary's parts" do
    {header, rows} = glossary()
    column = Enum.find_index(header, &(&1 == "Directory"))

    parts =
      for [name | _] = row <- rows,
          name =~ ~r/^[A-Z]/,
          Enum.at(row, column) != "—",
          do: name

    web =
      for dir <- glossary_column("Directory"),
          String.ends_with?(dir, "_web"),
          do: dir |> Path.basename() |> Macro.camelize()

    assert Enum.sort(Cyfr.Boundaries.product_roots()) == Enum.sort(parts ++ web),
           "Cyfr.Boundaries' product roots are not the glossary's parts and their web tiers"
  end

  test "the env template states the CORS allowlist's contract as the boot holds it" do
    # Unset or blank is the empty allowlist; the boot refuses the wildcard
    # once sign-in is configured (runtime_config_wiring_test.exs holds the
    # readings).
    lines = Path.join(@repo_root, ".env.example") |> File.read!() |> String.split("\n")
    at = Enum.find_index(lines, &(&1 == "CYFR_CORS_ALLOWED_ORIGINS="))
    assert at, ".env.example assigns no empty CYFR_CORS_ALLOWED_ORIGINS"

    comment =
      lines
      |> Enum.take(at)
      |> Enum.reverse()
      |> Enum.take_while(&String.starts_with?(&1, "#"))
      |> Enum.reverse()
      |> Enum.map_join(" ", &String.trim_leading(&1, "# "))

    assert comment =~ "Empty or unset admits no cross-origin client"
    assert comment =~ "refuses to boot on the wildcard `*` alone"
  end

  test "the glossary's directories, compose services and images are the tree's" do
    for dir <- glossary_column("Directory") do
      assert File.dir?(Path.join(@repo_root, dir)),
             "the glossary names #{dir}, which is not a directory"
    end

    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))
    services = compose_services(compose)

    assert Enum.sort(glossary_column("Compose service")) == Enum.sort(Map.keys(services)),
           "the glossary's compose services are not docker-compose.yml's"

    # The images the tag pipeline publishes, each from its Dockerfile.
    built =
      ~r/- image: ([a-z][a-z0-9-]*)\n\s+file: (\S+)/
      |> Regex.scan(File.read!(Path.join(@repo_root, ".github/workflows/release.yml")),
        capture: :all_but_first
      )
      |> Map.new(fn [image, file] -> {image, file} end)

    for {image, file} <- built do
      assert File.regular?(Path.join(@repo_root, file)),
             "release.yml builds #{image} from #{file}, which is missing"
    end

    images =
      glossary_column(
        "Binary or image",
        ~r/image `([a-z][a-z0-9-]*)`|`([a-z][a-z0-9-]*)` and `([a-z][a-z0-9-]*)` images/
      )

    assert Enum.sort(Enum.uniq(images)) == Enum.sort(Map.keys(built)),
           "the glossary's images #{inspect(images)} are not the ones release.yml builds"

    # Every image of ours compose runs is one the workflow publishes, built
    # from the Dockerfile the workflow builds it from.
    for {name, service} <- services,
        image = service.image,
        String.starts_with?(image, "ghcr.io/cyfrworks/") do
      published = image |> String.trim_leading("ghcr.io/cyfrworks/") |> String.split(":") |> hd()

      assert Map.has_key?(built, published),
             "compose's #{name} runs #{image}, which release.yml does not build"

      if service.dockerfile do
        assert service.dockerfile == built[published],
               "compose builds #{name} from #{service.dockerfile}, release.yml from #{built[published]}"
      end
    end
  end

  # ==========================================================================
  # One vocabulary
  #
  # The glossary names each namespace once, and the retired name of the
  # tenancy unit appears in no tracked file of the tree, the seed, the
  # image suites or the root guides. The pattern is the vocabulary-gate
  # job's, read from its step in the workflow, which owns it.
  # ==========================================================================

  @workflow Path.join(@repo_root, ".github/workflows/test.yml")
  @fossil_step "Retired names stay out and the storage layout is Arca's"

  # The directories that are namespaces: each application under apps/, and
  # each directory under the control plane's lib/ with a facade module
  # beside it, less the web tiers, which belong to their namespace.
  defp namespace_directories do
    apps =
      for path <- Path.wildcard(Path.join(@repo_root, "apps/*")),
          File.dir?(path),
          do: Path.basename(path)

    lib = Path.join(@repo_root, "apps/cyfr/lib")

    control_plane =
      for path <- Path.wildcard(Path.join(lib, "*")),
          File.dir?(path),
          name = Path.basename(path),
          File.regular?(Path.join(lib, name <> ".ex")),
          not String.ends_with?(name, "_web"),
          do: name

    Enum.uniq(apps ++ control_plane)
  end

  test "the glossary names every namespace directory under apps/ exactly once" do
    {_header, rows} = glossary()
    names = Enum.map(rows, &(&1 |> hd() |> String.downcase()))
    directories = namespace_directories()

    # Guards against the scan quietly matching nothing.
    assert "locus" in directories and "codex" in directories and "compendium" in directories

    counts =
      for directory <- directories,
          n = Enum.count(names, &(&1 == directory)),
          n != 1,
          do: {directory, n}

    assert counts == [],
           "each namespace directory is one glossary row; these are not ({directory, rows}): " <>
             inspect(counts)
  end

  # The retired-name pattern of the vocabulary-gate job: the one pattern of
  # its fossil loop that spells the capitalised form of the retired name.
  defp retired_name_pattern do
    workflow = File.read!(@workflow)

    [_, run] =
      Regex.run(
        ~r/- name: #{Regex.escape(@fossil_step)}\n\s+run: \|\n(.*?)\n\s+; do\n/s,
        workflow
      ) ||
        flunk("test.yml has no #{inspect(@fossil_step)} step with a fossil loop")

    patterns =
      for [pattern] <- Regex.scan(~r/^\s+'([^']+)' \\$/m, run, capture: :all_but_first),
          pattern =~ "[Ee]state",
          do: pattern

    case patterns do
      [pattern] -> Regex.compile!(pattern)
      other -> flunk("the fossil loop holds #{length(other)} retired-name patterns, not one")
    end
  end

  test "the retired-name pattern is read from the gate and reads the name, not English words" do
    pattern = retired_name_pattern()
    name = "e" <> "state"

    for line <- ["an #{name}", String.capitalize(name) <> "s", "my" <> String.capitalize(name)],
        do: assert(line =~ pattern, "the pattern misses #{inspect(line)}")

    for line <- ["re" <> name <> "d", "inter" <> name, "athanor"],
        do: refute(line =~ pattern, "the pattern reads #{inspect(line)}")
  end

  test "no tracked file under apps/, seed/, tests/ or the root guides says the retired name" do
    pattern = retired_name_pattern()

    {listing, 0} =
      System.cmd("git", ["ls-files", "-z", "--", "apps", "seed", "tests", ":(glob)*.md"],
        cd: @repo_root,
        env: [{"GIT_DIR", nil}, {"GIT_WORK_TREE", nil}, {"GIT_INDEX_FILE", nil}]
      )

    files = String.split(listing, <<0>>, trim: true)
    assert "README.md" in files and Enum.any?(files, &String.starts_with?(&1, "seed/"))

    hits =
      for rel <- files,
          path = Path.join(@repo_root, rel),
          File.regular?(path),
          text = File.read!(path),
          not String.contains?(text, <<0>>),
          {line, n} <- text |> String.split("\n") |> Enum.with_index(1),
          line =~ pattern,
          do: {rel, n}

    assert hits == [],
           "these lines say the retired name of the athanor: " <>
             Enum.map_join(hits, ", ", fn {rel, n} -> "#{rel}:#{n}" end)
  end

  # Check storage trees in the three compile-embedded operator guides.
  @guides ~w(component-guide.md tincture-guide.md integration-guide.md)

  test "every guide that draws the athanor tree names every tenant root" do
    for guide <- @guides do
      source = File.read!(Path.join(@repo_root, guide))

      # Only guides that actually draw the per-athanor tree are held to it.
      if source =~ "athanors/{athanor_id}/\n" or source =~ "└── athanors" or
           source =~ "athanors/{athanor_id}/`" do
        for root <- Arca.Storage.tenant_roots() do
          assert source =~ "#{root}/",
                 "tenant root #{root}/ is missing from #{guide}'s storage tree"
        end
      end
    end
  end

  test "component-guide's manifest field table documents the closed key roster" do
    source = File.read!(Path.join(@repo_root, "component-guide.md"))

    for key <- Prima.Manifest.known_keys() do
      assert source =~ "| `#{key}` |",
             "manifest key `#{key}` (Prima.Manifest.known_keys/0) is missing " <>
               "from component-guide.md's field table"
    end
  end

  # What a feed accepts is the envelope's data, held to the operation's
  # result shape: a component author writes an operation's answer against
  # this row, so the row itself says it.
  test "component-guide's results row says a result shape describes the envelope's data" do
    source = File.read!(Path.join(@repo_root, "component-guide.md"))

    [_, section] =
      Regex.run(~r/^### Field Reference\n(.*?)(?=^#)/ms, source) ||
        flunk("component-guide.md has no ### Field Reference section")

    assert [row] =
             for(
               line <- String.split(section, "\n"),
               String.starts_with?(line, "| `results` |"),
               do: line
             ),
           "component-guide.md's field table has no single `results` row"

    assert row =~ "| `results` | object | Optional |"
    assert row =~ ~s(`results[operation]` describes the `data` of the operation's)
    assert row =~ ~s(`{"status", "data"}` envelope)
    assert row =~ "a feed accepts only a 2xx envelope whose data matches"

    assert row =~
             "An error envelope, a non-2xx status or an output that is not an envelope is " <>
               "refused, for catalysts and formulas alike"
  end

  # ==========================================================================
  # integration-guide's two reference tables
  #
  # These are what an integrator writes their client against, and a wrong
  # reference is worse than a missing one, because it is followed: a client
  # waits for a code no producer mints, never backs off on a code the table
  # omits (`-33304 rate_limited`), and calls a tool the table publishes
  # without the credential it needs. So both tables are derived from the
  # code and checked in both directions.
  # ==========================================================================

  @integration_guide Path.join(@repo_root, "integration-guide.md")

  defp guide_error_codes do
    @integration_guide
    |> File.read!()
    |> then(&Regex.scan(~r/^\| (-33\d{3}) \| `(\w+)`/m, &1))
    |> Map.new(fn [_, code, name] -> {String.to_integer(code), name} end)
  end

  test "every CYFR error code in the guide's table is one the server can mint" do
    for {code, name} <- guide_error_codes() do
      atom = String.to_existing_atom(name)

      assert Prima.MCP.Message.error_code(atom) == code,
             "integration-guide documents #{code} `#{name}`, which " <>
               "Prima.MCP.Message does not define under that name — a client " <>
               "branching on it waits for a code that never arrives"
    end
  end

  test "every code a client could receive is in the guide's table" do
    documented = guide_error_codes() |> Map.keys() |> MapSet.new()

    missing =
      for {name, code} <- Prima.MCP.Message.cyfr_error_codes(),
          not MapSet.member?(documented, code),
          do: "#{code} #{name}"

    assert missing == [],
           "these codes reach clients but integration-guide's error table omits " <>
             "them: #{inspect(Enum.sort(missing))}"
  end

  # Every action a provider annotates `auth: :anonymous` — the actions that
  # answer without a session, which is exactly what the table claims to list.
  defp anonymous_actions do
    for provider <- Sanctum.Catalog.configured_providers(),
        tool <- provider.tools(),
        {action, meta} <- get_in(tool, [Access.key(:annotations, %{}), :actions]) || %{},
        meta[:auth] == :anonymous,
        do: {tool.name, action}
  end

  # Just the "Public Tools" section's table, so the check reads the rows
  # that make the claim and not every pipe-delimited row in the document
  # (permission scopes and HTTP headers are tables too).
  defp public_tools_rows do
    [_, section] =
      Regex.run(
        ~r/### Public Tools \(No Auth Required\)\n(.*?)\n### /s,
        File.read!(@integration_guide)
      )

    section
    |> then(&Regex.scan(~r/^\| `(\w+)` \| (.+?) \|/m, &1))
    |> Map.new(fn [_, tool, actions] -> {tool, actions} end)
  end

  test "the guide's public-tools table lists exactly the actions that need no session" do
    rows = public_tools_rows()
    anonymous = MapSet.new(anonymous_actions())

    # A guard against the check quietly matching nothing: the anonymous
    # surface is small but it is never empty, and neither is the table.
    assert MapSet.size(anonymous) > 0
    assert map_size(rows) > 0

    undocumented =
      for {tool, action} <- anonymous,
          row = Map.get(rows, tool),
          is_nil(row) or not String.contains?(row, "`#{action}`"),
          do: "#{tool}.#{action}"

    assert undocumented == [],
           """
           These actions answer with no credential at all, and
           integration-guide's "Public Tools" table does not list them:

           #{Enum.map_join(Enum.sort(undocumented), "\n", &"  #{&1}")}

           Either document them or drop the `auth: :anonymous` annotation —
           an anonymous action nobody wrote down is a surface nobody reviews.
           """

    # The other direction: an action the table lists as needing no auth
    # that needs a credential answers a client written from it `-33001` on
    # its first call. `auth: :signed_in` is NOT public — it serves a live
    # session, with or without an athanor to work in.
    overclaimed =
      for {tool, row} <- rows,
          [_, action] <- Regex.scan(~r/`(\w+)`/, row),
          not MapSet.member?(anonymous, {tool, action}),
          do: "#{tool}.#{action}"

    assert overclaimed == [],
           """
           These are listed as needing no authentication, but the dispatcher
           refuses them to an uncredentialed caller:

           #{Enum.map_join(Enum.sort(overclaimed), "\n", &"  #{&1}")}
           """
  end

  # cyfr's side of the worker wire, as `config/runtime.exs` and the
  # resolvers it calls read it, is documented in the configuration guide.
  test "every worker variable of cyfr's that the runtime configuration reads is in the configuration guide" do
    read =
      for file <-
            ~w(config/runtime.exs apps/cyfr/lib/cyfr/runtime_config.ex
               apps/cyfr/lib/cyfr/platform/settings/roster.ex),
          [name] <-
            Regex.scan(
              ~r/"(CYFR_LOCUS_RUNTIME_[A-Z0-9_]+|CYFR_HOST_API_[A-Z0-9_]+)"/,
              File.read!(Path.join(@repo_root, file)),
              capture: :all_but_first
            ),
          uniq: true,
          do: name

    assert length(read) >= 6, "the scan found only #{inspect(read)}"

    guide = documented_in_guide(File.read!(@configuration_guide))
    undocumented = Enum.reject(read, &MapSet.member?(guide, &1))

    assert undocumented == [],
           "config/runtime.exs reads these worker variables, and configuration-guide.md " <>
             "does not document them: #{inspect(undocumented)}"
  end

  # ==========================================================================
  # Where each setting of the worker and the builder is documented
  #
  # Compose hands a service the values its `environment:` names, over
  # anything its own env file sets: the locus-runtime service gets its id,
  # its key and the host URL interpolated from the project .env and a fixed
  # bind address and port; the builds service gets its key from .env's
  # CYFR_LOCUS_BUILDS_KEY. So a variable the locus release reads has one
  # place an operator sets it, and the documentation is there alone:
  #
  #   * `.env.example`, for what compose interpolates from the project .env;
  #   * the services' own example (`.env.locus.example`, one file for every
  #     role), for what its env file can set;
  #   * integration-guide.md's "Running a worker outside Compose", for what
  #     compose fixes and a release run without it is given itself.
  #
  # Every name the `cyfr` boot reads has its home in `configuration-guide.md`,
  # rendered from `Cyfr.Platform.Settings.Roster`; `.env.example` is the
  # starting `.env`, a selection of the guide's names, so a name the guide
  # documents counts there alone.
  #
  # The rules are functions of the files' text, so the planted violations
  # below prove each one fails.
  # ==========================================================================

  @outside_compose "Running a worker outside Compose"

  # The names an env example documents: its assignment lines, commented or
  # not.
  defp documented(text) do
    ~r/^#?[ \t]*([A-Z][A-Z0-9_]*)=/m
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  # The names configuration-guide.md documents: the first cell of each row
  # of its tables, where it is one backquoted name.
  defp documented_in_guide(guide) do
    ~r/^\| `([A-Z][A-Z0-9_]*)` \|/m
    |> Regex.scan(guide, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  # The names integration-guide.md's section on running a worker outside
  # Compose documents: the first cell of each row of its tables.
  defp documented_outside_compose(guide) do
    case Regex.run(~r/^### #{@outside_compose}\n(.*?)(?=^[#]{2,3} |\z)/ms, guide) do
      [_, section] ->
        for [cell] <- Regex.scan(~r/^\| (`[A-Z].*?) \|/m, section, capture: :all_but_first),
            [name] <- Regex.scan(~r/`([A-Z][A-Z0-9_]*)`/, cell, capture: :all_but_first),
            into: MapSet.new(),
            do: name

      nil ->
        MapSet.new()
    end
  end

  # The variables the locus release reads from its operator: the
  # LOCUS_RUNTIME_*, LOCUS_BUILDS_*, LOCUS_BACKENDS_* and LOCUS_LOG_* rows
  # of Locus.Config's roster (the runner's RUNTIME_* are its service's and
  # the keeper's, set on a runner, not an operator's).
  defp release_variables(locus_config) do
    Regex.scan(~r/"(LOCUS_(?:RUNTIME|BUILDS|BACKENDS|LOG)_[A-Z0-9_]+)"/, locus_config,
      capture: :all_but_first
    )
    |> List.flatten()
    |> Enum.uniq()
  end

  # Each service's env files other than the project .env, and the names its
  # `environment:` sets, from docker-compose.yml.
  defp compose_services(compose) do
    [_, services | _] = Regex.split(~r/^services:\s*$/m, compose)
    [services | _] = Regex.split(~r/^[a-z]/m, services)

    for [name, block] <-
          Regex.scan(~r/^  ([a-z][a-z0-9_-]*):\s*\n(.*?)(?=^  [a-z]|\z)/ms, services,
            capture: :all_but_first
          ),
        into: %{} do
      env_files =
        for [path] <-
              Regex.scan(~r/^      - (?:path: )?(\.env[^\s]*)$/m, list_block(block, "env_file"),
                capture: :all_but_first
              ),
            path != ".env",
            do: path

      set =
        for [var] <-
              Regex.scan(~r/^      - ([A-Z][A-Z0-9_]*)=/m, list_block(block, "environment"),
                capture: :all_but_first
              ),
            do: var

      image = with [_, image] <- Regex.run(~r/^    image: (\S+)$/m, block), do: image
      dockerfile = with [_, file] <- Regex.run(~r/^      dockerfile: (\S+)$/m, block), do: file

      {name, %{env_files: env_files, environment: set, image: image, dockerfile: dockerfile}}
    end
  end

  defp list_block(block, key) do
    case Regex.split(~r/^    #{key}:\s*$/m, block) do
      [_, rest | _] -> rest |> then(&Regex.split(~r/^    [a-z]/m, &1)) |> hd()
      _ -> ""
    end
  end

  # The documentation texts the rules read, by the name a failure shows.
  defp homes do
    Map.new(
      ~w(.env.example .env.locus.example integration-guide.md configuration-guide.md),
      &{&1, File.read!(Path.join(@repo_root, &1))}
    )
  end

  # Rule 1: every variable a release reads is documented in exactly one
  # home. Answers the violations, `{variable, homes}`.
  defp misplaced(variables, homes) do
    guide = documented_in_guide(homes["configuration-guide.md"])

    documented_in = %{
      ".env.example" => MapSet.difference(documented(homes[".env.example"]), guide),
      ".env.locus.example" => documented(homes[".env.locus.example"]),
      "integration-guide.md" => documented_outside_compose(homes["integration-guide.md"]),
      "configuration-guide.md" => guide
    }

    for variable <- variables,
        found = for({home, names} <- documented_in, variable in names, do: home),
        length(found) != 1,
        do: {variable, Enum.sort(found)}
  end

  # Rule 2: no service's own example documents a variable compose's
  # `environment:` for that service overrides. Answers `{example, variable}`.
  defp overridden(services, homes) do
    for {_service, %{env_files: files, environment: set}} <- services,
        file <- files,
        example = file <> ".example",
        variable <- set,
        variable in documented(Map.fetch!(homes, example)),
        do: {example, variable}
  end

  # Rule 3: `.env.example` documents a worker or builder variable only when
  # compose interpolates it from the project .env; any other reaches no
  # service from there. Answers the variables.
  defp stranded(compose, homes) do
    interpolated =
      ~r/\$\{([A-Z][A-Z0-9_]*)/ |> Regex.scan(compose, capture: :all_but_first) |> List.flatten()

    for variable <- documented(homes[".env.example"]),
        String.starts_with?(variable, [
          "LOCUS_RUNTIME_",
          "LOCUS_BUILDS_",
          "LOCUS_BACKENDS_",
          "LOCUS_LOG_"
        ]),
        variable not in interpolated,
        do: variable
  end

  defp placement_inputs do
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    variables =
      release_variables(File.read!(Path.join(@repo_root, "apps/locus/lib/locus/config.ex")))

    {compose, compose_services(compose), variables, homes()}
  end

  test "every worker and builder variable is documented where an operator sets it, and only there" do
    {compose, services, variables, homes} = placement_inputs()

    # Guards against the scans quietly matching nothing.
    assert "LOCUS_RUNTIME_KEY" in variables and "LOCUS_RUNTIME_BIND" in variables
    assert "LOCUS_BUILDS_KEY" in variables and "LOCUS_BUILDS_MEMORY_BYTES" in variables
    assert "LOCUS_BACKENDS_KEY" in variables and "LOCUS_BACKENDS_MEMORY_BYTES" in variables
    assert length(variables) >= 27, "the scan found only #{inspect(variables)}"
    assert "LOCUS_LOG_LEVEL" in variables
    assert services["locus-runtime"].env_files == [".env.locus"]
    assert "LOCUS_RUNTIME_BIND" in services["locus-runtime"].environment
    assert services["locus-builds"].environment == ["LOCUS_BUILDS_KEY"]
    assert services["locus-backends"].environment == ["LOCUS_BACKENDS_KEY"]
    assert services["locus-backends"].env_files == [".env.locus"]

    for {_service, %{env_files: files}} <- services, file <- files do
      assert Map.has_key?(homes, file <> ".example"),
             "docker-compose.yml names #{file}, and no #{file}.example documents it"
    end

    assert misplaced(variables, homes) == [],
           """
           Each of these is documented in no home or in more than one: an \
           operator must find one place to set it (.env.example for what \
           compose interpolates from .env, the service's own example for what \
           its env file sets, integration-guide.md's "#{@outside_compose}" \
           for what compose fixes):

           #{inspect(misplaced(variables, homes))}
           """

    assert overridden(services, homes) == [],
           "these service examples document a variable docker-compose.yml's `environment:` " <>
             "for that service overrides, so setting it there does nothing: " <>
             inspect(overridden(services, homes))

    assert stranded(compose, homes) == [],
           ".env.example documents these, and docker-compose.yml takes none of them from " <>
             ".env: #{inspect(stranded(compose, homes))}"
  end

  test "a variable documented in the wrong home fails the rules" do
    {compose, services, variables, homes} = placement_inputs()

    plant = fn file, line -> Map.update!(homes, file, &(&1 <> "\n" <> line <> "\n")) end

    # The key compose hands the worker from .env, documented in its own
    # file as well: there twice, and overridden where it was planted.
    planted = plant.(".env.locus.example", "# LOCUS_RUNTIME_KEY=")

    assert {"LOCUS_RUNTIME_KEY", [".env.example", ".env.locus.example"]} in misplaced(
             variables,
             planted
           )

    assert {".env.locus.example", "LOCUS_RUNTIME_KEY"} in overridden(services, planted)

    # A fixed value documented in the project .env: there twice, and read
    # from .env by nothing.
    planted = plant.(".env.example", "# LOCUS_RUNTIME_BIND=0.0.0.0")

    assert {"LOCUS_RUNTIME_BIND", [".env.example", "integration-guide.md"]} in misplaced(
             variables,
             planted
           )

    assert "LOCUS_RUNTIME_BIND" in stranded(compose, planted)

    # The builder's key in its own file, which compose overrides.
    planted = plant.(".env.locus.example", "# LOCUS_BUILDS_KEY=")
    assert {".env.locus.example", "LOCUS_BUILDS_KEY"} in overridden(services, planted)

    # The backends key likewise, which compose hands the backends service.
    planted = plant.(".env.locus.example", "# LOCUS_BACKENDS_KEY=")
    assert {".env.locus.example", "LOCUS_BACKENDS_KEY"} in overridden(services, planted)

    assert {"LOCUS_BACKENDS_KEY", [".env.locus.example", "integration-guide.md"]} in misplaced(
             variables,
             planted
           )

    # A backends setting documented in the project .env as well: there
    # twice, and read from .env by nothing.
    planted = plant.(".env.example", "# LOCUS_BACKENDS_PORT=4101")

    assert {"LOCUS_BACKENDS_PORT", [".env.example", ".env.locus.example"]} in misplaced(
             variables,
             planted
           )

    assert "LOCUS_BACKENDS_PORT" in stranded(compose, planted)

    # A platform setting of the control plane's documented in a service's
    # example as well as in the guide.
    planted = plant.(".env.locus.example", "# CYFR_SESSION_TTL_HOURS=720")

    assert {"CYFR_SESSION_TTL_HOURS", [".env.locus.example", "configuration-guide.md"]} in misplaced(
             ["CYFR_SESSION_TTL_HOURS"],
             planted
           )

    # A setting documented nowhere.
    unplanted =
      Map.update!(
        homes,
        ".env.locus.example",
        &String.replace(&1, "# LOCUS_RUNTIME_POOL_SIZE=", "#")
      )

    assert {"LOCUS_RUNTIME_POOL_SIZE", []} in misplaced(variables, unplanted)

    # A guide section that loses its table documents nothing.
    renamed =
      Map.update!(
        homes,
        "integration-guide.md",
        &String.replace(&1, @outside_compose, "Elsewhere")
      )

    assert {"LOCUS_RUNTIME_PORT", []} in misplaced(variables, renamed)
  end

  # Compose reads the variables it interpolates from the project .env, so
  # each is documented where an operator looks for it: the service settings
  # in the env example or the guide that owns them, and the containers' own
  # limits, which no release reads, in `.env.example` beside the settings
  # they hold.
  test "every variable docker-compose.yml interpolates is documented in an env example or the guide" do
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    interpolated =
      ~r/\$\{([A-Z][A-Z0-9_]*)(?::?-[^}]*)?\}/
      |> Regex.scan(compose, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(interpolated) >= 15, "the scan found only #{inspect(interpolated)}"

    documented =
      for example <- Path.wildcard(Path.join(@repo_root, ".env*.example"), match_dot: true),
          [_, name] <- Regex.scan(~r/^#?\s*([A-Z][A-Z0-9_]*)=/m, File.read!(example)),
          into: documented_in_guide(File.read!(@configuration_guide)),
          do: name

    undocumented = Enum.reject(interpolated, &MapSet.member?(documented, &1))

    assert undocumented == [],
           "docker-compose.yml reads these from the project .env, and neither an env " <>
             "example nor configuration-guide.md documents them: #{inspect(undocumented)}"

    # The containers' limits are compose's alone: documented where compose
    # reads them, and read by no release.
    project = File.read!(Path.join(@repo_root, ".env.example"))
    runtime = File.read!(Path.join(@repo_root, "config/runtime.exs"))
    locus_runtime = File.read!(Path.join(@repo_root, "apps/locus/lib/locus/config.ex"))

    runtime_settings =
      File.read!(Path.join(@repo_root, "apps/locus/lib/locus/runtime/settings.ex"))

    for limit <- Enum.filter(interpolated, &String.ends_with?(&1, "_LIMIT")) do
      assert project =~ ~r/^# #{limit}=/m, "#{limit} is not documented in .env.example"
      refute runtime =~ limit, "config/runtime.exs reads the compose-only #{limit}"
      refute locus_runtime =~ limit, "Locus.Config reads the compose-only #{limit}"
      refute runtime_settings =~ limit, "runtime/settings.ex reads the compose-only #{limit}"
    end
  end

  # The builds service is two variables, read by one resolver
  # (`Cyfr.RuntimeConfig.resolve_locus_builds/1`), which `.env.example`
  # assigns for `cyfr init` to complete: the compose service's URL, and the
  # key init mints. The configuration guide documents each.
  test "the builds service's variables are assigned in .env.example and documented in the guide" do
    read =
      @repo_root
      |> Path.join("apps/cyfr/lib/cyfr/runtime_config.ex")
      |> File.read!()
      |> then(&Regex.scan(~r/"(CYFR_LOCUS_BUILDS_[A-Z0-9_]+)"/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert read == ["CYFR_LOCUS_BUILDS_KEY", "CYFR_LOCUS_BUILDS_URL"]

    project = File.read!(Path.join(@repo_root, ".env.example"))
    configuration = documented_in_guide(File.read!(@configuration_guide))

    for name <- read do
      assert project =~ ~r/^#{name}=/m, "#{name} is not assigned in .env.example"
      assert name in configuration, "#{name} is not in configuration-guide.md"
    end

    assert project =~ ~r/^CYFR_LOCUS_BUILDS_URL=http:\/\/locus-builds:4100$/m
    assert project =~ ~r/^CYFR_LOCUS_BUILDS_KEY=$/m
  end

  # The backends service is four variables of the control plane's, read by
  # `config/runtime.exs` (its two periods through the platform settings
  # roster), documented in the configuration guide; `.env.example` assigns
  # the key for `cyfr init` to mint, and compose sets the URL.
  test "the backends service's variables are documented in the guide, its key in .env.example" do
    read =
      ~w(config/runtime.exs apps/cyfr/lib/cyfr/platform/settings/roster.ex)
      |> Enum.map_join("\n", &File.read!(Path.join(@repo_root, &1)))
      |> then(&Regex.scan(~r/"(CYFR_LOCUS_BACKENDS_[A-Z0-9_]+)"/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert read == [
             "CYFR_LOCUS_BACKENDS_IDLE_MS",
             "CYFR_LOCUS_BACKENDS_KEY",
             "CYFR_LOCUS_BACKENDS_LEASE_MS",
             "CYFR_LOCUS_BACKENDS_URL"
           ]

    project = File.read!(Path.join(@repo_root, ".env.example"))
    configuration = documented_in_guide(File.read!(@configuration_guide))

    for name <- read do
      assert name in configuration, "#{name} is not in configuration-guide.md"
    end

    assert project =~ ~r/^CYFR_LOCUS_BACKENDS_KEY=$/m

    assert File.read!(Path.join(@repo_root, "docker-compose.yml")) =~
             "CYFR_LOCUS_BACKENDS_URL=${CYFR_LOCUS_BACKENDS_URL:-http://locus-backends:4101}"
  end

  # Every build and every runner is bounded by a cgroup of its own, which
  # the host provides only with Docker Engine 28 or later on cgroup v2 and
  # the containers' option: the guides an operator deploys from say so, and
  # say what they see without it and what `OOMKilled` means.
  test "the deployment guides state the Docker requirement, what fails without it, and OOMKilled" do
    for guide <- ~w(README.md integration-guide.md) do
      text = File.read!(Path.join(@repo_root, guide))

      for needle <- [
            "Docker Engine 28 or later",
            "cgroup v2",
            "writable-cgroups=true",
            "refused as `unavailable`",
            "OOMKilled"
          ] do
        assert text =~ needle, "#{guide} does not say #{inspect(needle)}"
      end
    end

    readme = File.read!(@readme)
    assert readme =~ ~r/^\| `locus-builds` \*\(profile: `locus-builds`\)\* \|/m
  end

  # What `describe` may answer, as `Aqua.Models` reads it, is what the
  # guide documents for a catalyst author.
  test "every field Aqua.Models reads from describe is in the component guide" do
    read =
      @repo_root
      |> Path.join("apps/cyfr/lib/aqua/models.ex")
      |> File.read!()
      |> then(&Regex.scan(~r/described\["([a-z_]+)"\]/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    assert "max_input_tokens" in read and "context_window" in read

    guide = File.read!(Path.join(@repo_root, "component-guide.md"))

    for field <- read do
      assert guide =~ "`#{field}`" or guide =~ ~s("#{field}"),
             "component-guide.md does not document describe's #{field}"
    end
  end

  # A pin the control plane refuses reaches the guest as one of the
  # engine's error types (`Locus.Runtime.Egress`), and the fetch interface's error
  # list in the component guide names every one.
  test "component-guide's fetch error types name every type a refused pin reaches the guest as" do
    answered =
      @repo_root
      |> Path.join("apps/locus/lib/locus/runtime/egress.ex")
      |> File.read!()
      |> then(&Regex.scan(~r/\{:(?:refused|error), :([a-z_]+),/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    assert "redirect_credentials" in answered and "private_ip_blocked" in answered

    guide = File.read!(Path.join(@repo_root, "component-guide.md"))

    [_, types] =
      Regex.run(~r/^### `cyfr:http\/fetch`.*?^Error: `\{"error": \{"type": "([a-z_|]+)"/ms, guide)

    documented = String.split(types, "|")

    assert answered -- documented == [],
           "component-guide.md's fetch error types lack #{inspect(answered -- documented)}"
  end

  # The envelope a host function answers a guest's error with is the shared
  # vectors' (`Prima.WitResponse`'s test reads the same file), wherever
  # component-guide spells it: the Error: lines of `cyfr:http/fetch` and
  # `cyfr:storage/files`, and the Invoke Error Types, whose table names the
  # fallback's type and the member a setup_required error carries besides.
  # The error types themselves are held to their producers by the fetch
  # error check above. The `model/chat@1` refusal, with its `provider`
  # member, is a model catalyst's own result, not this envelope.
  test "component-guide's error envelope and its fallback type are the guest error vectors'" do
    vectors =
      @repo_root
      |> Path.join("tests/fixtures/guest_error.json")
      |> File.read!()
      |> Jason.decode!()

    %{"member" => member, "fields" => [type, message], "setup_member" => setup_member} =
      vectors["envelope"]

    guide = File.read!(Path.join(@repo_root, "component-guide.md"))

    section = fn heading ->
      case Regex.run(~r/^#{Regex.escape(heading)}.*?(?=^##)/ms, guide) do
        [text] -> text
        nil -> flunk("component-guide.md has no #{heading} section")
      end
    end

    envelope = ~r/\{"#{member}": \{"#{type}": "[a-z_|.]+", "#{message}": "\.\.\."\}\}/

    for heading <- ["### `cyfr:http/fetch`", "### `cyfr:storage/files`"] do
      assert [[line]] =
               Regex.scan(~r/^Error: `(.*)`/m, section.(heading), capture: :all_but_first),
             "component-guide.md's #{heading} has no single Error: line"

      assert line =~ ~r/\A#{envelope.source}\z/,
             "component-guide.md's #{heading} spells an error as #{line}"
    end

    invoke = section.("### Invoke Error Types")

    assert invoke =~
             ~r/^Errors returned by `invoke::call`\/`invoke::spawn` as `#{envelope.source}`:$/m,
           "component-guide.md's Invoke Error Types do not spell the vectors' envelope"

    fallback = vectors["fallback"]["answer"][member][type]

    assert invoke =~ ~r/^\| `#{fallback}` \| A tool's result could not be encoded as JSON \|$/m,
           "component-guide.md's Invoke Error Types have no #{fallback} row"

    assert invoke =~ ~r/^\| `setup_required` \| .* — includes `#{setup_member}` field \|$/m,
           "component-guide.md's setup_required row does not name its #{setup_member} member"
  end

  # Guide table rows that quote a refusal's sentence, each held to
  # `Prima.Refusal`: exactly one row whose first cell is the entry's,
  # quoting the sentence the person or guest reads. `{class}` in a cell is
  # the refusal's class, so a row that names its class holds that too.
  # A write into a version directory no committed revision names reaches a
  # storage guest as `storage_path_denied` with the `:no_unit` sentence
  # (`Opus.GuestStorage`); an in-chain call whose handler stopped once it
  # may have acted reaches a formula as `uncertain` with the gate's
  # sentence (`Sanctum.Dispatch.uncertain_message/2`, through
  # `Opus.Host.Children`).
  @quoted_refusals [
    {{:reserved_path, ["aqua", ".staging"]}, "`{class}` (reserved path)"},
    {:no_unit, "`storage_path_denied`"},
    {{:uncertain, Sanctum.Dispatch.uncertain_message("<name>", :crashed)}, "`uncertain`"}
  ]

  test "component-guide's rows that quote a refusal hold its class and sentence" do
    guide = File.read!(Path.join(@repo_root, "component-guide.md"))

    for {reason, cell} <- @quoted_refusals do
      %Prima.Refusal{class: class, message: message} = Prima.Refusal.classify(reason)
      cell = String.replace(cell, "{class}", Atom.to_string(class))

      rows =
        Regex.scan(~r/^\| #{Regex.escape(cell)} \|(.*)\|$/m, guide, capture: :all_but_first)

      assert length(rows) == 1,
             "component-guide.md has #{length(rows)} rows whose first cell is #{cell}, not one"

      [[row]] = rows

      assert row =~ ~s("#{message}"),
             "component-guide.md's #{cell} row does not quote #{inspect(reason)}'s sentence"
    end
  end

  # ==========================================================================
  # Every variable the releases read has one home, and every documented
  # name is read
  #
  # The rules above place the worker and builder variables; this holds the
  # whole set, every `CYFR_*`, `LOCUS_*`, `KEEPER_*` and `RUNTIME_*` name the
  # releases' readers and the keeper read, to the shipped examples, and
  # each example to what something reads.
  # ==========================================================================

  # Read by a release, set by no operator: the process that starts the
  # reader hands each over, so no example documents it.
  @set_by_the_starter %{
    # The keeper sets it for the client it starts; an inherited value is
    # replaced, never read.
    "KEEPER_CHANNEL" => :keeper,
    # The worker service hands each runner its role and identities
    # (`Locus.Runtime.Settings.runner_environment/1`). cyfr-locus places
    # the control channel and the relay on file descriptors 3 and 4, which
    # a runner reads by contract; the test build's direct launcher names
    # its control descriptor and a relay socket in their place.
    "RUNTIME_ROLE" => :worker_service,
    "RUNTIME_RUNNER_ID" => :worker_service,
    "RUNTIME_SERVICE_ID" => :worker_service,
    "RUNTIME_BOOT_ID" => :worker_service,
    "RUNTIME_WATCHDOG_GRACE_MS" => :worker_service,
    "RUNTIME_CONTROL_FD" => :keeper,
    "RUNTIME_RELAY_SOCKET" => :keeper
  }

  # Every quoted upper-case name the releases' readers spell: what a
  # documented name must be read as, whatever its prefix.
  defp spelled_by_readers do
    not_read = spelled_not_read()

    for file <- @env_readers ++ keeper_sources(),
        [name] <-
          Regex.scan(~r/"([A-Z][A-Z0-9_]*[A-Z0-9])"/, File.read!(Path.join(@repo_root, file)),
            capture: :all_but_first
          ),
        not MapSet.member?(not_read, name),
        into: MapSet.new(),
        do: name
  end

  test "every variable the releases read is documented in exactly one home" do
    read = read_variables()
    homes = homes()

    for {name, _starter} <- @set_by_the_starter do
      assert name in read, "#{name} is on the set-by-the-starter roster, and nothing reads it"

      for {home, text} <- homes, home != "integration-guide.md" do
        refute name in documented(text), "#{home} documents #{name}, which no operator sets"
      end
    end

    violations =
      read
      |> Enum.reject(&Map.has_key?(@set_by_the_starter, &1))
      |> misplaced(homes)

    assert violations == [],
           """
           Each of these is read by a release and documented in no home or in \
           more than one ({variable, homes}):

           #{inspect(violations)}
           """
  end

  # The compose-only class and the deployment list are the roster's
  # (`Cyfr.Platform.Settings.Roster`), which derives the first from
  # docker-compose.yml and holds it there; this reads them from their owner.
  test "every name a shipped example documents is read by a release or by compose" do
    read =
      MapSet.union(
        spelled_by_readers(),
        MapSet.new(Roster.compose_only() ++ Roster.deployment() ++ Roster.variables())
      )

    unread =
      for example <- ~w(.env.example .env.locus.example),
          name <- documented(File.read!(Path.join(@repo_root, example))),
          not MapSet.member?(read, name),
          do: {example, name}

    assert unread == [],
           "these examples document names no release reads and compose does not " <>
             "interpolate: #{inspect(unread)}"
  end

  # ==========================================================================
  # The deployment file and the configuration guide
  #
  # `.env.example` is the starting `.env`: the lines `cyfr init` rewrites
  # or completes, assigned, and the deployment's choices commented out.
  # `configuration-guide.md` is the roster's render, every name and setting
  # with its sentence.
  # ==========================================================================

  # The names `.env.example` assigns: the keys and addresses `cyfr init`
  # mints, writes or completes, and the access mode every deployment decides,
  # `local` until `cyfr init` or `cyfr access` writes another.
  @deployment_file_assignments ~w(
    CYFR_SECRET_KEY_BASE CYFR_ACCESS CYFR_HOST CYFR_PORT
    CYFR_CORS_ALLOWED_ORIGINS CYFR_PRIVATE_EGRESS_TARGETS CYFR_GITHUB_CLIENT_ID
    CYFR_GOOGLE_CLIENT_ID CYFR_LOCUS_RUNTIME_ROOT LOCUS_RUNTIME_KEY CYFR_LOCUS_BACKENDS_KEY
    CYFR_LOCUS_BUILDS_URL CYFR_LOCUS_BUILDS_KEY
  )

  test "the deployment file assigns init's lines, keeps its anchor and holds no platform setting" do
    text = File.read!(Path.join(@repo_root, ".env.example"))

    assigned =
      for [name] <- Regex.scan(~r/^([A-Z][A-Z0-9_]*)=/m, text, capture: :all_but_first),
          do: name

    assert Enum.sort(assigned) == Enum.sort(@deployment_file_assignments),
           ".env.example assigns #{inspect(assigned)}"

    # No line names an operator or a sign-in provider: the installation's
    # administrator is the first person setup makes, and a sign-in method
    # is offered exactly when its credentials are set.
    refute text =~ "CYFR_PLATFORM_ADMIN_EMAILS"
    refute text =~ "CYFR_AUTH_PROVIDER"

    settings = MapSet.new(Roster.variables())

    assert Enum.filter(documented(text), &MapSet.member?(settings, &1)) == [],
           ".env.example documents platform settings, which the guide and the Settings page hold"

    declared = MapSet.new(Roster.deployment() ++ Roster.compose_only())

    stray =
      for name <- documented(text),
          String.starts_with?(name, "CYFR_"),
          not MapSet.member?(declared, name),
          do: name

    assert stray == [], ".env.example documents #{inspect(stray)}, no deployment variable"

    assert length(String.split(text, "configuration-guide.md")) == 2,
           ".env.example points at configuration-guide.md once"
  end

  test "configuration-guide.md is the roster's render" do
    assert File.read!(@configuration_guide) == ConfigurationGuide.render(),
           "configuration-guide.md is stale: run `mix cyfr.gen.configuration_guide`"
  end

  test "the guide lists every name the roster declares, each once, with its sentence" do
    text = File.read!(@configuration_guide)

    listed =
      ~r/^\| `([A-Z][A-Z0-9_]*)` \|/m
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()

    exact_foreign =
      for {name, _owner} <- Roster.foreign(), not String.ends_with?(name, "*"), do: name

    assert Enum.sort(listed) ==
             Enum.sort(
               Roster.deployment() ++ Roster.variables() ++ Roster.compose_only() ++ exact_foreign
             )

    for {name, doc} <- Roster.deployment_docs() ++ Roster.compose_only_docs() do
      assert is_binary(doc) and String.trim(doc) != "", "#{name} has no sentence"
    end

    lines = String.split(text, "\n")

    for %Entry{} = entry <- Roster.entries() do
      assert is_binary(entry.doc) and String.trim(entry.doc) != "", "#{entry.key} has no doc"

      row =
        Enum.find(lines, &String.starts_with?(&1, "| `#{entry.variable}` | `#{entry.key}` |")) ||
          flunk("configuration-guide.md has no row for #{entry.key}")

      assert row =~ "| `#{entry.group}` | #{entry.scope} | #{entry.stale} | #{entry.doc} |"
    end

    [_, recovery] = String.split(text, "## Headless recovery\n", parts: 2)
    assert recovery =~ "bin/cyfr rpc" and recovery =~ "bin/cyfr eval"
  end

  # ==========================================================================
  # integration-guide's scope, key-type, vault and consent-walk tables
  # ==========================================================================

  # The rows of the first table under `heading` in `path` (the integration
  # guide unless named), up to the next heading, each as its trimmed cells.
  defp guide_table(heading, path \\ @integration_guide) do
    guide = File.read!(path)

    [_, section] =
      Regex.run(~r/^#{Regex.escape(heading)}\n(.*?)(?=^#)/ms, guide) ||
        flunk("#{Path.basename(path)} has no section #{inspect(heading)}")

    rows =
      for line <- String.split(section, "\n"),
          String.starts_with?(line, "|"),
          not (line =~ ~r/^\|[\s|:-]+\|$/),
          do: line |> String.trim("|") |> String.split(~r/(?<!\\)\|/) |> Enum.map(&String.trim/1)

    [_header | body] = rows
    assert body != [], "the table under #{heading} has no rows"
    body
  end

  defp backquoted(cell),
    do: ~r/`([^`]+)`/ |> Regex.scan(cell, capture: :all_but_first) |> List.flatten()

  test "the guide's scope table is Sanctum's permission roster" do
    documented = for [scope | _] <- guide_table("### Available Scopes"), do: hd(backquoted(scope))

    assert Enum.sort(documented) == Enum.sort(Sanctum.Atoms.known_permissions()),
           "integration-guide.md's scopes #{inspect(documented)} are not " <>
             "Sanctum.Atoms.known_permissions/0"
  end

  test "the guide's key-type table is Sanctum.ApiKey's defaults and ceilings" do
    rows = guide_table("#### Key Type Defaults and Ceilings")

    documented =
      Map.new(rows, fn [type, defaults, ceiling] ->
        [_, name] = Regex.run(~r/\*\*(\w+)\*\*/, type)

        {String.to_existing_atom(String.downcase(name)),
         {Jason.decode!(hd(backquoted(defaults))), Jason.decode!(hd(backquoted(ceiling)))}}
      end)

    expected =
      Map.new(Sanctum.ApiKey.type_defaults(), fn {type, defaults} ->
        {type, {defaults, Map.fetch!(Sanctum.ApiKey.type_ceilings(), type)}}
      end)

    assert documented == expected,
           "integration-guide.md's key-type defaults and ceilings are not Sanctum.ApiKey's"
  end

  # The operations of the configured tool named `tool`, by action.
  defp operations(tool) do
    definition =
      Enum.find_value(Sanctum.Catalog.configured_providers(), fn provider ->
        Enum.find(provider.tools(), &(&1.name == tool))
      end)

    assert definition, "no configured provider serves #{tool}"
    Map.new(definition.operations, &{&1.action, &1})
  end

  # A tool's action table: the actions are the tool's, each once, and every
  # name the key-args column backquotes is an argument of that action or a
  # value one of its arguments enumerates.
  defp assert_action_table(heading, tool) do
    rows = guide_table(heading)
    operations = operations(tool)
    documented = for [action | _] <- rows, do: hd(backquoted(action))

    assert Enum.sort(documented) == Enum.sort(Map.keys(operations)),
           "integration-guide.md's #{tool} actions #{inspect(documented)} are not the " <>
             "operations #{tool} declares, #{inspect(Enum.sort(Map.keys(operations)))}"

    for [action, args | _] <- rows,
        action = hd(backquoted(action)),
        %Prima.Operation{args: declared} <- [operations[action]] do
      known = Enum.flat_map(declared, &[&1.name | &1.enum || []])

      for name <- backquoted(args) do
        assert name in known,
               "integration-guide.md names `#{name}` for #{tool}.#{action}, which declares " <>
                 inspect(Enum.map(declared, & &1.name))
      end
    end
  end

  test "the guide's vault table is the vault tool's operations" do
    assert_action_table("### The vault (`vault` tool)", "vault")
  end

  test "the guide's consent-walk table is the profile tool's operations" do
    assert_action_table("### The consent walk (`profile` tool)", "profile")
  end

  test "the guide's canvas table is the canvas tool's operations" do
    assert_action_table("### Canvases (`canvas` tool)", "canvas")
  end

  # component-guide's CLI-to-MCP table names, for each command, the tool
  # and the actions a formula calls in its place: every pair is one the
  # catalog serves, and every argument the key-args column backquotes as a
  # bare name is one those actions declare or enumerate. A value it shows
  # in another shape (a flag, an answer's fields) is not an argument.
  test "component-guide's CLI-to-MCP table names only operations the catalog serves" do
    rows =
      guide_table("#### CLI → MCP Tool Reference", Path.join(@repo_root, "component-guide.md"))

    for [cli, tool, actions, args] <- rows do
      [tool] = backquoted(tool)
      operations = operations(tool)
      named = backquoted(actions)
      assert named != [], "component-guide.md's row for #{cli} names no action"

      for action <- named do
        assert Map.has_key?(operations, action),
               "component-guide.md maps #{cli} to #{tool}.#{action}, which the catalog does " <>
                 "not serve; #{tool} declares #{inspect(Enum.sort(Map.keys(operations)))}"
      end

      known =
        for action <- named,
            %Prima.Operation{args: declared} <- [Map.fetch!(operations, action)],
            arg <- declared,
            name <- [arg.name | arg.enum || []],
            do: name

      [asked | _returned] = String.split(args, "→")

      for name <- backquoted(asked), name =~ ~r/^[a-z_]+$/ do
        assert name in known,
               "component-guide.md names `#{name}` for #{cli} (#{tool}.#{Enum.join(named, "/")}), " <>
                 "which declares none such"
      end
    end
  end

  # A feed's press is an external operation and nothing narrower: the shell
  # sends a canvas's control to it, and the CLI and the API reach it as any
  # external operation, never from a chain. So the tincture guide says that
  # from a canvas only the person's press runs it, and the integration
  # guide's press row says who reaches it.
  test "a feed's press is an external operation" do
    %Prima.Operation{planes: planes} = Map.fetch!(operations("feed"), "press")

    assert planes == [:external],
           "feed.press declares the planes #{inspect(planes)}; the guides say it is external " <>
             "only, so either declare it so or say in both guides who reaches it"

    press =
      for [action | _] = row <- guide_table("### Feeds (`feed` tool)"),
          backquoted(action) == ["press"],
          do: row

    assert File.read!(Path.join(@repo_root, "tincture-guide.md")) =~
             "From a canvas, a feed's action runs only on the person's press of a control",
           "tincture-guide.md does not say that from a canvas only the person's press runs " <>
             "a feed's action"

    assert [row] = press, "integration-guide.md's feed table has no single `press` row"

    assert List.last(row) =~ "the CLI and the API reach it",
           "integration-guide.md's `press` row does not say the CLI and the API reach it"
  end

  # ==========================================================================
  # integration-guide's typed-errors table and the paragraph under it
  #
  # The typed errors are the consent signals, `Prima.ConsentSignal`'s tags,
  # each with the payload `Sanctum.Consent` types for it. The table names
  # each once with those keys; the paragraph under it names each tag's MCP
  # code and the HTTP status `confirmation_required` answers.
  # ==========================================================================

  # The keys of `Sanctum.Consent`'s `@type <tag> :: %{…}`, in order, read
  # inside that type up to its own closing brace, so a key of another type
  # cannot stand in for a missing one.
  defp consent_payload_keys(tag) do
    consent = File.read!(Path.join(@repo_root, "apps/sanctum/lib/sanctum/consent.ex"))

    [body] =
      Regex.run(~r/^  @type #{tag} :: %\{\n(.*?)\n\s*\}$/ms, consent, capture: :all_but_first) ||
        flunk("Sanctum.Consent declares no map type #{tag}")

    ~r/^\s*(\w+):/m |> Regex.scan(body, capture: :all_but_first) |> List.flatten()
  end

  test "the guide's typed-errors table is the consent signals, each with its payload" do
    tags = Enum.map(Prima.ConsentSignal.tags(), &Atom.to_string/1)
    assert length(tags) == 4

    documented =
      for [error, payload | _] <- guide_table("### Readiness and typed errors") do
        [tag] = backquoted(error)
        [keys] = backquoted(payload)
        {tag, keys |> String.trim_leading("{") |> String.trim_trailing("}") |> split_keys()}
      end

    assert Enum.sort(Enum.map(documented, &elem(&1, 0))) == Enum.sort(tags),
           "integration-guide.md's typed errors #{inspect(Enum.map(documented, &elem(&1, 0)))} " <>
             "are not the consent signals #{inspect(tags)}, each once"

    for {tag, keys} <- documented do
      assert keys == consent_payload_keys(tag),
             "integration-guide.md documents #{tag}'s payload as #{inspect(keys)}; " <>
               "Sanctum.Consent types it #{inspect(consent_payload_keys(tag))}"
    end

    [_, section] =
      Regex.run(
        ~r/^### Readiness and typed errors\n(.*?)(?=^### )/ms,
        File.read!(@integration_guide)
      )

    [paragraph] =
      Regex.run(~r/^On the MCP wire each arrives .*$/m, section) ||
        flunk("the typed errors have no paragraph naming their MCP codes")

    pairs = Regex.scan(~r/`(-335\d\d)` \(`(\w+)`\)/, paragraph, capture: :all_but_first)

    assert Enum.sort(for [_code, tag] <- pairs, do: tag) == Enum.sort(tags),
           "the paragraph names the codes of #{inspect(for [_code, tag] <- pairs, do: tag)}, " <>
             "not of every consent signal once"

    for [code, tag] <- pairs do
      assert Prima.MCP.Message.error_code(String.to_existing_atom(tag)) == String.to_integer(code),
             "the paragraph gives #{tag} the code #{code}, which Prima.MCP.Message does not"
    end

    [_, status] =
      Regex.run(~r/`confirmation_required` at `(\d{3}) /, paragraph) ||
        flunk("the paragraph names no HTTP status for confirmation_required")

    assert String.to_integer(status) == CyfrWeb.ApiError.status(:confirmation_required),
           "the paragraph's HTTP status for confirmation_required is not CyfrWeb.ApiError's"
  end

  defp split_keys(keys), do: keys |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # ==========================================================================
  # component-guide's WIT blocks
  # ==========================================================================

  # A WIT text's package, its interfaces as name to the sorted function
  # lines, and its worlds as name to {exports, imports}, comments dropped
  # and whitespace collapsed.
  defp wit(text) do
    text =
      text
      |> String.replace(~r{//[^\n]*}, "")
      |> String.replace(~r/\s+/, " ")

    [_, package] = Regex.run(~r/package ([^;]+);/, text)

    interfaces =
      for [_, name, body] <- Regex.scan(~r/interface ([\w-]+) \{(.*?)\}/, text), into: %{} do
        functions =
          body
          |> String.split(";", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {name, Enum.sort(functions)}
      end

    worlds =
      for [_, name, body] <- Regex.scan(~r/world ([\w-]+) \{(.*?)\}/, text), into: %{} do
        items = body |> String.split(";", trim: true) |> Enum.map(&String.trim/1)
        exports = for "export " <> item <- items, do: item
        imports = for "import " <> item <- items, do: item
        {name, {Enum.sort(exports), Enum.sort(imports)}}
      end

    %{package: package, interfaces: interfaces, worlds: worlds}
  end

  # The canonical world of each component type, by package.
  defp canonical_wits do
    for path <- Path.wildcard(Path.join(@repo_root, "wit/*/world.wit")), into: %{} do
      wit = wit(File.read!(path))
      {wit.package, wit}
    end
  end

  test "component-guide's WIT blocks are the canonical worlds, a catalyst's imports a subset" do
    guide = File.read!(Path.join(@repo_root, "component-guide.md"))
    canonical = canonical_wits()
    blocks = Regex.scan(~r/^```wit\n(.*?)^```/ms, guide, capture: :all_but_first)

    assert length(blocks) >= 3, "component-guide.md shows only #{length(blocks)} WIT blocks"

    for [block] <- blocks do
      shown = wit(block)

      canon =
        Map.get(canonical, shown.package) ||
          flunk("component-guide.md shows package #{shown.package}, which wit/ does not declare")

      for {name, functions} <- shown.interfaces do
        assert Map.get(canon.interfaces, name) == functions,
               "component-guide.md's #{shown.package} interface #{name} is #{inspect(functions)}; " <>
                 "wit/ declares #{inspect(canon.interfaces[name])}"
      end

      for {name, {exports, imports}} <- shown.worlds do
        {canon_exports, canon_imports} =
          Map.get(canon.worlds, name) ||
            flunk(
              "component-guide.md shows world #{name}, which #{shown.package} does not declare"
            )

        assert exports == canon_exports, "world #{name} exports #{inspect(exports)}"

        assert imports -- canon_imports == [],
               "world #{name} imports #{inspect(imports -- canon_imports)}, which wit/ does not"

        # Only a catalyst chooses its imports; every other world is shown whole.
        unless shown.package =~ "catalyst",
          do: assert(imports == canon_imports, "world #{name} is not shown whole")
      end
    end

    # Every canonical world is shown at least once.
    shown_packages = for [block] <- blocks, into: MapSet.new(), do: wit(block).package
    assert MapSet.new(Map.keys(canonical)) == shown_packages
  end

  test "component-guide names every function of the invoke interface and of each host interface heading" do
    guide = File.read!(Path.join(@repo_root, "component-guide.md"))
    formula = canonical_wits() |> Map.values() |> Enum.find(&(&1.package =~ "formula"))

    invoke =
      for function <- formula.interfaces["invoke"],
          do: function |> String.split(":", parts: 2) |> hd()

    [_, listed] = Regex.run(~r/The full `invoke` interface \(with (.*?)\)/, guide)
    assert Enum.sort(backquoted(listed)) == Enum.sort(invoke)

    # Each `### `cyfr:<package>/<interface>` — `<function>(…` heading names
    # a function its interface declares.
    deps =
      for path <- Path.wildcard(Path.join(@repo_root, "wit/*/deps/*/*.wit")),
          wit = wit(File.read!(path)),
          [package | _] = String.split(wit.package, "@"),
          {interface, functions} <- wit.interfaces,
          into: %{},
          do: {"#{package}/#{interface}", Enum.map(functions, &hd(String.split(&1, ":")))}

    headings =
      Regex.scan(~r/^### `(cyfr:[a-z]+\/[a-z-]+)` — `([a-z-]+)\(/m, guide,
        capture: :all_but_first
      )

    assert headings != []

    for [interface, function] <- headings do
      assert function in Map.get(deps, interface, []),
             "component-guide.md heads #{interface} with #{function}, which it does not declare"
    end
  end

  # ==========================================================================
  # The tincture lists: tincture-guide.md and the Artisan role, from the
  # frame's rules and the wire
  #
  # Each list is a block between `<!-- tincture:NAME -->` and
  # `<!-- /tincture:NAME -->`, written as `tincture_list/1` renders it from
  # `Compendium`'s tincture rules and `Prima.TinctureWire`. A block that
  # differs fails with the rendering to paste, so a list the rules grow
  # reaches the guide and the role before any reader meets a stale one.
  # ==========================================================================

  @tincture_list_files ["tincture-guide.md", "seed/aqua/roles/artisan.md"]
  @tincture_lists ~w(served-types frame-capabilities templates declaration wire-routes sdk)

  # The SDK's call for each request kind, and the arguments of each shell
  # verb: the JavaScript names of what the wire names.
  @sdk_requests %{
    invoke: {"invoke", "ref, operation, args"},
    action: {"action", "name, args"},
    stream_open: {"stream", "name, subject, onEvent"}
  }
  @sdk_verb_args %{open: "ref", title: "title", credential: "name"}

  defp tincture_list("served-types") do
    rows =
      for {extension, type} <- Enum.sort(Compendium.tincture_served_types()),
          do: "| `#{extension}` | `#{type}` |"

    ["| Extension | Served as |", "|---|---|" | rows]
  end

  defp tincture_list("frame-capabilities") do
    rows =
      for capability <- Compendium.Tincture.Rules.frame_capabilities() do
        {:ok, ["allow-scripts" | sandbox]} = Compendium.tincture_sandbox_tokens([capability])
        {:ok, allow} = Compendium.tincture_allow_attribute([capability])

        "| `#{capability}` | #{code_or_none(Enum.join(sandbox, " "))} | #{code_or_none(allow)} |"
      end

    ["| Capability | `sandbox` adds | `allow` adds |", "|---|---|---|" | rows]
  end

  defp tincture_list("templates") do
    rows =
      for %{name: name, build: build, entry: entry} <- Compendium.tincture_templates(),
          do: "| `#{name}` | #{code_or_none(build || "")} | `#{entry}` |"

    ["| Template | Build | Entry |", "|---|---|---|" | rows]
  end

  defp tincture_list("declaration") do
    keys = fn struct -> struct |> Map.from_struct() |> Map.keys() |> Enum.sort() end
    list = fn names -> Enum.map_join(names, ", ", &"`#{&1}`") end

    [
      "| Block | Keys |",
      "|---|---|",
      "| `frame` | #{list.(keys.(%Prima.Manifest.Tincture.Frame{}))} |",
      "| `frame.placement` | one of #{list.(Compendium.Tincture.Rules.placements())} |",
      "| `canvas` | #{list.(keys.(%Prima.Manifest.Tincture.Canvas{}))} |",
      "| `streams[]` | #{list.(keys.(%Prima.Manifest.Tincture.Stream{name: ""}))} |",
      "| `actions[]` | an operation name, `tool.action` |"
    ]
  end

  defp tincture_list("wire-routes") do
    rows =
      for kind <- Prima.TinctureWire.kinds(),
          do: "| `#{kind}` | `POST #{Prima.TinctureWire.route(kind)}` |"

    ["| Request | Route |", "|---|---|" | rows]
  end

  defp tincture_list("sdk") do
    requests =
      for kind <- Prima.TinctureWire.kinds() do
        {name, args} = Map.fetch!(@sdk_requests, kind)
        "| `cyfr.#{name}(#{args})` | `POST #{Prima.TinctureWire.route(kind)}` |"
      end

    verbs =
      for verb <- Prima.TinctureWire.verbs(),
          do:
            "| `cyfr.#{verb}(#{Map.get(@sdk_verb_args, verb, "")})` | the shell's port, `#{verb}` |"

    ["| Call | Carried by |", "|---|---|" | requests ++ verbs]
  end

  defp code_or_none(""), do: "—"
  defp code_or_none(value), do: "`#{value}`"

  defp tincture_block(text, name) do
    case Regex.run(~r/<!-- tincture:#{name} -->\n(.*?)\n<!-- \/tincture:#{name} -->/s, text,
           capture: :all_but_first
         ) do
      [block] -> block
      nil -> nil
    end
  end

  test "the tincture guide's and the Artisan role's lists are the rules' and the wire's" do
    for file <- @tincture_list_files, name <- @tincture_lists do
      text = File.read!(Path.join(@repo_root, file))
      expected = Enum.join(tincture_list(name), "\n")

      assert tincture_block(text, name) == expected,
             """
             #{file}'s #{name} list is not the rules' (or it has no block). It reads:

             <!-- tincture:#{name} -->
             #{expected}
             <!-- /tincture:#{name} -->
             """
    end
  end

  test "the SDK's calls are the wire's request kinds and shell verbs" do
    client = File.read!(Path.join(@repo_root, "apps/cyfr/assets/js/sdk/client.js"))
    [_, api] = Regex.run(~r/const api = \{(.*?)\n  \}\n/s, client)

    methods =
      ~r/^    ([a-z]+)\(/m
      |> Regex.scan(api, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    wire =
      Enum.map(Prima.TinctureWire.kinds(), &elem(Map.fetch!(@sdk_requests, &1), 0)) ++
        Enum.map(Prima.TinctureWire.verbs(), &Atom.to_string/1)

    assert methods == Enum.sort(wire),
           "the SDK's calls #{inspect(methods)} are not the wire's #{inspect(Enum.sort(wire))}"
  end

  # The elements a canvas's tree may name are the toolkit's `ELEMENTS`
  # (`elements.js`), which its own tests hold to the grammar (`tree.js`).
  # The guide lists them, one per line and in that order, in a block the
  # Artisan role does not carry.
  test "the tincture guide's canvas elements are the toolkit's" do
    source = File.read!(Path.join(@repo_root, "apps/cyfr/assets/js/toolkit/elements.js"))

    [_, list] =
      Regex.run(~r/^export const ELEMENTS = Object\.freeze\(\[(.*?)\]\)/ms, source) ||
        flunk("elements.js declares no `export const ELEMENTS = Object.freeze([…])`")

    elements = ~r/"([^"]+)"/ |> Regex.scan(list, capture: :all_but_first) |> List.flatten()

    assert elements != [], "elements.js's ELEMENTS names no element"

    # Every entry is a double-quoted name: anything else in the list would
    # be an element this reading drops, and the guide would pass without it.
    assert Regex.replace(~r/"[^"]+"|,|\s/, list, "") == "",
           "elements.js's ELEMENTS holds something other than double-quoted names"

    expected = Enum.map_join(elements, "\n", &"- `#{&1}`")
    guide = File.read!(Path.join(@repo_root, "tincture-guide.md"))

    assert tincture_block(guide, "canvas-elements") == expected,
           """
           tincture-guide.md's canvas-elements list is not the toolkit's ELEMENTS (or it has no block). It reads:

           <!-- tincture:canvas-elements -->
           #{expected}
           <!-- /tincture:canvas-elements -->
           """
  end

  # A layout is published only through the layout tool: `layout.edit`
  # (`Compendium.Providers.Layout`) is `Arca.Layouts.publish/4`'s one
  # caller, and every shell, the canvas and safe mode only read the layout.
  # The tincture guide names that tool as how a layout is published, and
  # the writers the code admits.
  test "a layout is published only through the layout tool" do
    publisher = "apps/cyfr/lib/compendium/providers/layout.ex"

    callers =
      for path <- Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.ex")),
          File.read!(path) =~
            ~r/\bLayouts\.publish\b|alias Arca\.Layouts,\s*as:|import Arca\.Layouts\b/,
          do: Path.relative_to(path, @repo_root)

    assert callers == [publisher],
           "Arca.Layouts.publish is reached from #{inspect(callers)}, not from #{publisher} " <>
             "alone: publish a layout only through the layout tool's edit"

    guide = File.read!(Path.join(@repo_root, "tincture-guide.md"))

    [paragraph] =
      Regex.run(~r/^The person's \*\*layout\*\* .*$/m, guide) ||
        flunk("tincture-guide.md has no paragraph beginning \"The person's **layout**\"")

    assert paragraph =~ "A layout is published only through the `layout` tool's `edit`",
           "tincture-guide.md's layout paragraph does not say a layout is published only " <>
             "through the `layout` tool's `edit`"

    # Who reaches the tool: the CLI, the API and a glass paired with the
    # person from outside, and the assistant from a run. No tincture
    # declares it, a manifest of any type but an agent's may not name it,
    # and the shipped soul asks the person before it edits.
    %Prima.Operation{planes: planes} = Map.fetch!(operations("layout"), "edit")

    assert :external in planes and :in_chain in planes,
           "layout.edit declares the planes #{inspect(planes)}; the guide names callers from " <>
             "outside and from a run, so say in it who reaches the tool"

    manifest = %{
      "type" => "tincture",
      "tincture" => %{"frame" => %{"placement" => "float"}, "actions" => ["layout.edit"]}
    }

    assert {:error, {:invalid_tincture, sentence}} = Compendium.tincture_declaration(manifest),
           "a tincture may declare layout.edit; say so in tincture-guide.md's " <>
             "layout paragraph"

    assert sentence =~ "layout.edit"

    for type <- ["catalyst", "reagent", "formula", "tincture"] do
      assert Prima.Manifest.Caps.validate(
               %{"type" => type, "caps" => %{"tools" => ["layout.edit"]}},
               &Arca.Storage.valid_guest_path?/1
             ) == {:error, {:invalid_caps, {:agent_only_tool, "layout.edit"}}},
             "a #{type}'s caps may name layout.edit; say so in tincture-guide.md's " <>
               "layout paragraph"
    end

    assert :ok =
             Prima.Manifest.Caps.validate(
               %{"type" => "agent", "caps" => %{"tools" => ["layout.edit"]}},
               &Arca.Storage.valid_guest_path?/1
             )

    # A schedule's writes are an agent's alone too, as the tincture guide's
    # refused actions and the component guide's `caps.tools` row say.
    for tool <- ["schedule.create", "schedule.update"] do
      manifest = %{
        "type" => "tincture",
        "tincture" => %{"frame" => %{"placement" => "float"}, "actions" => [tool]}
      }

      assert {:error, {:invalid_tincture, sentence}} = Compendium.tincture_declaration(manifest),
             "a tincture may declare #{tool}; say so in tincture-guide.md's actions"

      assert sentence =~ tool

      for type <- ["catalyst", "reagent", "formula", "tincture"] do
        assert Prima.Manifest.Caps.validate(
                 %{"type" => type, "caps" => %{"tools" => [tool]}},
                 &Arca.Storage.valid_guest_path?/1
               ) == {:error, {:invalid_caps, {:agent_only_tool, tool}}},
               "a #{type}'s caps may name #{tool}; say so in component-guide.md"
      end

      assert :ok =
               Prima.Manifest.Caps.validate(
                 %{"type" => "agent", "caps" => %{"tools" => [tool]}},
                 &Arca.Storage.valid_guest_path?/1
               )
    end

    # Both guides state the whole agent-only set, from its one list.
    component_guide = File.read!(Path.join(@repo_root, "component-guide.md"))

    [tools_row] =
      Regex.run(~r/^\| `tools` \|.*$/m, component_guide) ||
        flunk("component-guide.md has no `tools` row")

    [feed_paragraph] =
      Regex.run(~r/^\*\*Binding a feed\.\*\*.*$/m, component_guide) ||
        flunk("component-guide.md has no paragraph beginning \"**Binding a feed.**\"")

    [refused_actions] =
      Regex.run(~r/^- An action is an operation name.*$/m, guide) ||
        flunk("tincture-guide.md has no line beginning \"- An action is an operation name\"")

    for tool <- Prima.Manifest.Caps.agent_only_tools(),
        {text, where} <- [
          {tools_row, "component-guide.md's `tools` row"},
          {feed_paragraph, "component-guide.md's feed-binding paragraph"},
          {refused_actions, "tincture-guide.md's actions line"}
        ] do
      assert text =~ "`#{tool}`", "#{where} does not name the agent-only tool #{tool}"
    end

    {:ok, soul} =
      Compendium.AquaAgent.parse(
        "aqua",
        File.read!(Path.join(@repo_root, "seed/aqua/aqua.md"))
      )

    assert soul.tool_policy["layout.edit"] == "ask",
           "the shipped soul's policy holds layout.edit at #{inspect(soul.tool_policy["layout.edit"])}; " <>
             "tincture-guide.md's layout paragraph says it asks the person first"

    for writer <- [
          "The CLI, the API and a device paired with the person call it for the person",
          "the assistant, whose shipped policy asks the person first",
          "No tincture declares `layout.edit`"
        ] do
      assert paragraph =~ writer,
             "tincture-guide.md's layout paragraph does not say #{inspect(writer)}"
    end
  end

  # A layout is one fenced document per person per athanor: its key names
  # the person alone, and the athanor is the document's own.
  test "the tincture guide says a person has one layout in each athanor" do
    assert Arca.Layouts.key("usr_1") == "layouts/usr_1",
           "a layout's document key names more than the person; say in tincture-guide.md's " <>
             "layout paragraph how many layouts a person has"

    [paragraph] =
      Regex.run(~r/^The person's \*\*layout\*\* .*$/m, tincture_guide()) ||
        flunk("tincture-guide.md has no paragraph beginning \"The person's **layout**\"")

    assert paragraph =~ "A person has one layout in each athanor.",
           "tincture-guide.md's layout paragraph does not say a person has one layout in each " <>
             "athanor"
  end

  # The toolkit's module worker fails the canvas on an error the module
  # throws or a rejection nothing handles, and the shell takes that failure
  # as safe mode `crashed`. The guide's toolkit section says so, so a canvas
  # author catches a refused stream rather than losing the canvas to it.
  test "the tincture guide says an uncaught error in a canvas module fails the canvas" do
    worker = File.read!(Path.join(@repo_root, "apps/cyfr/assets/js/toolkit/worker.js"))

    for event <- ["error", "unhandledrejection"] do
      assert worker =~ ~s{listen("#{event}", () => fail("runtime"))},
             "the toolkit's module worker does not fail the canvas on #{event}; say what it " <>
               "does in tincture-guide.md's toolkit section"
    end

    [_, after_heading] =
      String.split(tincture_guide(), "### The toolkit and the tree\n", parts: 2)

    [section | _] = String.split(after_heading, "\n### ", parts: 2)

    assert section =~
             "An error the module does not catch fails the canvas: a throw out of its code, " <>
               "or a rejection nothing handles, such as a refused `canvas.stream` without a " <>
               "`catch`, puts the shell into safe mode (`crashed`).",
           "tincture-guide.md's toolkit section does not say an uncaught error in the module " <>
             "fails the canvas into safe mode"
  end

  defp tincture_guide, do: File.read!(Path.join(@repo_root, "tincture-guide.md"))

  test "the tincture guide states the lockfile, the invoke input, the referrer policy and the log rule" do
    guide = File.read!(Path.join(@repo_root, "tincture-guide.md"))

    assert guide =~ "`#{Compendium.Tincture.Rules.lockfile()}`"
    assert guide =~ ~s({"operation": …, "params": …})
    assert guide =~ "Referrer-Policy: no-referrer"
    assert guide =~ ~r/no proxy may log `\/_s\/` paths/i
  end

  # ==========================================================================
  # integration-guide.md and the configuration guide
  #
  # Every variable and setting of the `cyfr` server is the configuration
  # guide's, rendered from the roster. integration-guide.md points at it
  # and lists none of its names in a table of its own: a copied table is
  # one that drifts from the roster.
  # ==========================================================================

  # The configuration guide's names that a table row of `guide` begins
  # with, each once.
  defp repeated_settings(guide, configuration) do
    for line <- String.split(guide, "\n"),
        String.starts_with?(line, "| `"),
        [first | _] = line |> String.trim_leading("|") |> String.split("|"),
        [name] <- Regex.scan(~r/`([A-Z][A-Z0-9_]*)`/, first, capture: :all_but_first),
        MapSet.member?(configuration, name),
        uniq: true,
        do: name
  end

  test "integration-guide.md points at the configuration guide and repeats none of its names" do
    guide = File.read!(@integration_guide)
    configuration = documented_in_guide(File.read!(@configuration_guide))

    assert guide =~ "[configuration-guide.md](configuration-guide.md)",
           "integration-guide.md does not point at configuration-guide.md"

    assert repeated_settings(guide, configuration) == [],
           "integration-guide.md's tables repeat what configuration-guide.md documents: " <>
             inspect(repeated_settings(guide, configuration))

    # A planted row of the server's is caught, and so is one of two names.
    planted = guide <> "\n| `CYFR_HOST` | `localhost` | The host |\n"
    assert repeated_settings(planted, configuration) == ["CYFR_HOST"]

    planted = guide <> "\n| `CYFR_S3_BUCKET` / `CYFR_S3_REGION` | — | For S3 |\n"
    assert repeated_settings(planted, configuration) == ["CYFR_S3_BUCKET", "CYFR_S3_REGION"]
  end

  # ==========================================================================
  # The shipped guides
  #
  # The scaffold tarball's items (scripts/scaffold-tarball.sh) are the
  # guides a project ships, and every guide at the repository's root is
  # one of them; codex's managed list holds the same set (`scaffold.Guides`,
  # under its own test). Every other copy of the list names the same
  # guides: README's `cyfr init` paragraph, its project tree and its
  # documentation table; the workflow's path filters, so a change to a guide
  # runs the suite that reads it; and the vocabulary gate's paths.
  # ==========================================================================

  defp shipped_guides do
    script = File.read!(Path.join(@repo_root, "scripts/scaffold-tarball.sh"))

    [_, items] =
      Regex.run(~r/\nITEMS=\((.*?)\n\)/s, script) ||
        flunk("scaffold-tarball.sh has no ITEMS list")

    items
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.flat_map(&String.split/1)
    |> Enum.filter(&String.ends_with?(&1, "-guide.md"))
    |> Enum.sort()
  end

  defp readme_section(heading) do
    [_, section] =
      Regex.run(~r/^#{Regex.escape(heading)}\n(.*?)(?=^## )/ms, File.read!(@readme)) ||
        flunk("README.md has no section #{inspect(heading)}")

    section
  end

  defp guide_names(text, pattern),
    do: pattern |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> Enum.sort()

  test "every copy of the shipped-guide list names the guides the scaffold ships" do
    shipped = shipped_guides()
    assert "identity-guide.md" in shipped and "devices-guide.md" in shipped

    root =
      @repo_root
      |> Path.join("*-guide.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert root == shipped,
           "the root guides #{inspect(root)} are not the ones the scaffold ships #{inspect(shipped)}"

    [_, included] =
      Regex.run(~r/the included guides \((.*?)\)\./, File.read!(@readme)) ||
        flunk("README.md's `cyfr init` paragraph names no included guides")

    copies = [
      {"README.md's `cyfr init` paragraph", included, ~r/\[([a-z-]+-guide\.md)\]/},
      {"README.md's project tree", readme_section("## Project Layout"),
       ~r/^├── ([a-z-]+-guide\.md) /m},
      {"README.md's documentation table", readme_section("## Documentation"),
       ~r/^\| \[[^\]]+\]\(([a-z-]+-guide\.md)\)/m}
    ]

    [triggers | _] = String.split(File.read!(@workflow), "\njobs:\n", parts: 2)

    [_, push, pull_request] =
      Regex.run(~r/^  push:\n(.*?)^  pull_request:\n(.*?)^  [a-z_]+:/ms, triggers) ||
        flunk("test.yml has no push and pull_request triggers")

    filters = ~r/^      - '([a-z-]+-guide\.md)'$/m

    copies =
      copies ++
        [
          {"test.yml's push paths", push, filters},
          {"test.yml's pull_request paths", pull_request, filters}
        ]

    for {copy, text, pattern} <- copies do
      assert guide_names(text, pattern) == shipped,
             "#{copy} names #{inspect(guide_names(text, pattern))}, " <>
               "not the guides the scaffold ships #{inspect(shipped)}"
    end

    # The vocabulary gate's two file lists: the retired names' paths, and
    # the guides its storage-diagram check reads.
    workflow = File.read!(@workflow)

    gate_lists = [
      {"the vocabulary gate's paths", ~r/^\s+paths='([^']+)'$/m},
      {"the vocabulary gate's storage-diagram files",
       ~r/^\s+python3 -I scripts\/ci\/storage-diagrams\.py ([^|]+) \|\| fail=1$/m}
    ]

    for {copy, pattern} <- gate_lists do
      [_, files] = Regex.run(pattern, workflow) || flunk("test.yml has no #{copy}")

      guides =
        files |> String.split() |> Enum.filter(&String.ends_with?(&1, "-guide.md")) |> Enum.sort()

      assert guides == shipped,
             "#{copy} name #{inspect(guides)}, not the guides the scaffold ships #{inspect(shipped)}"
    end
  end

  # ==========================================================================
  # identity-guide.md and devices-guide.md
  #
  # The guides a person reads name the settings that bound what they see
  # and the variables an operator sets for them. Each name is the roster's,
  # a value a guide gives a variable is one the roster accepts, and each
  # default a guide states is the roster's.
  # ==========================================================================

  @people_guides ~w(identity-guide.md devices-guide.md)

  # The spans the guides spell a default in, in seconds. A default spelled
  # any other way fails until it is read here.
  @spelled_spans %{"five minutes" => 300, "one hour" => 3_600}

  defp stated_default(phrase) do
    case Integer.parse(phrase) do
      {seconds, ""} ->
        seconds

      _ ->
        Map.get(@spelled_spans, phrase) ||
          flunk("a guide states a default as #{inspect(phrase)}, which this test does not read")
    end
  end

  test "the identity and devices guides name the roster's settings and variables, with its defaults" do
    entries = Map.new(Roster.entries(), &{&1.key, &1})
    by_variable = Map.new(Roster.entries(), &{&1.variable, &1})
    declared = MapSet.new(Roster.deployment() ++ Roster.variables())

    seen =
      for guide <- @people_guides, reduce: %{keys: 0, variables: 0, defaults: 0} do
        seen ->
          text = File.read!(Path.join(@repo_root, guide))

          # Every backquoted snake-case name that is a setting's, and every
          # one spelled like a duration setting: a misspelt key fails.
          keys =
            for [token] <-
                  Regex.scan(~r/`([a-z][a-z0-9]*(?:_[a-z0-9]+)+)`/, text, capture: :all_but_first),
                Map.has_key?(entries, token) or String.ends_with?(token, "_seconds"),
                uniq: true,
                do: token

          for key <- keys do
            assert Map.has_key?(entries, key),
                   "#{guide} names the setting #{key}, which the roster lacks"
          end

          # A variable, with the value a guide gives it when it gives one.
          variables =
            for [name | value] <-
                  Regex.scan(~r/`(CYFR_[A-Z0-9_]+)(?:=([^`]*))?`/, text, capture: :all_but_first),
                do: {name, List.first(value, "")}

          for {name, value} <- variables do
            assert MapSet.member?(declared, name),
                   "#{guide} names #{name}, which the roster lacks"

            if value != "" and Map.has_key?(by_variable, name) do
              assert match?({:ok, _}, by_variable[name].validator.(value)),
                     "#{guide} sets #{name}=#{value}, which the roster refuses"
            end
          end

          defaults =
            Regex.scan(~r/`([a-z][a-z0-9_]*)`(?: \(|, )([a-z0-9 ]+?) by default/, text,
              capture: :all_but_first
            )

          for [key, phrase] <- defaults do
            entry =
              Map.get(entries, key) || flunk("#{guide} states a default for #{key}, no setting")

            assert stated_default(phrase) == entry.default,
                   "#{guide} says #{key} defaults to #{phrase}; " <>
                     "the roster's default is #{inspect(entry.default)}"
          end

          %{
            keys: seen.keys + length(keys),
            variables: seen.variables + length(variables),
            defaults: seen.defaults + length(defaults)
          }
      end

    # Guards against the scans quietly matching nothing.
    assert seen.keys >= 5 and seen.variables >= 5 and seen.defaults >= 5, inspect(seen)
  end

  # The identity guide's loss table has no owner in code to drift from; it
  # is held as the contract it states: every row says what was lost, what
  # still works and how the person comes back, and the last row is the one
  # loss no recovery answers, which only starting again as a new person does.
  test "the identity guide's loss table keeps its columns and its last row" do
    guide = File.read!(Path.join(@repo_root, "identity-guide.md"))

    [_, section] =
      Regex.run(~r/^## What Each Loss Costs\n(.*?)(?=^## |\z)/ms, guide) ||
        flunk("identity-guide.md has no section What Each Loss Costs")

    [header, _rule | rows] =
      for line <- String.split(section, "\n"),
          String.starts_with?(line, "|"),
          do: line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

    assert header == ["You lost", "What still works", "How you come back"]
    assert length(rows) >= 8, "the loss table has #{length(rows)} rows"
    assert Enum.all?(rows, &(length(&1) == 3)), "a loss row does not have three cells"

    [lost, works, back] = List.last(rows)
    assert lost =~ "every kit" and lost =~ "online keys"
    assert works =~ "Nothing"
    assert back =~ "new person"
  end
end
