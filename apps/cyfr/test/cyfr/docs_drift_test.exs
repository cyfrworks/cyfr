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

  @repo_root Path.expand("../../../..", __DIR__)
  @readme Path.join(@repo_root, "README.md")

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
  @env_prefixes ~w(CYFR_ CYFR_OPUS_ CYFR_CRUCIBLE_ CYFR_HOST_API_ CYFR_LOCUS_BUILDS_
                   CYFR_LOCUS_BACKENDS_ OPUS_ LOCUS_BUILDS_ LOCUS_BACKENDS_ KEEPER_)
  @glossary_names ~w(Prima Arca Sanctum Grimoire Cyfr Compendium Aqua Crucible Emissary Prism Codex Opus Locus keeper
                     actor athanor)

  # The files that read the releases' environment: the control plane's
  # configuration (the `CYFR_*` variables `config/runtime.exs` reads into
  # the operator keys of `Cyfr.Boundaries.config_key_classes/0`, the
  # resolvers it calls, and the platform settings roster whose variables it
  # reads), the Opus release's `OPUS_*` rows in the same file, the Locus
  # release's `Locus.Config`, the Opus settings, and the keeper's own
  # sources (`keeper_sources/0`).
  @env_readers ~w(config/runtime.exs apps/cyfr/lib/cyfr/runtime_config.ex
                  apps/cyfr/lib/cyfr/platform/settings/roster.ex
                  apps/locus/lib/locus/config.ex apps/opus/lib/opus/settings.ex)

  # The names the roster spells that no release reads: those other
  # programs own (`Roster.foreign/0`), which their owners document, and
  # those compose reads alone (`Roster.compose_only/0`).
  defp spelled_not_read do
    MapSet.new(Enum.map(Roster.foreign(), &elem(&1, 0)) ++ Roster.compose_only())
  end

  # The keeper's Go sources other than its tests, relative to the root.
  defp keeper_sources do
    @repo_root
    |> Path.join("apps/keeper/**/*.go")
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

  defp read_variables do
    not_read = spelled_not_read()

    for file <- @env_readers ++ keeper_sources(),
        [name] <-
          Regex.scan(
            ~r/"((?:CYFR|OPUS|LOCUS|KEEPER)_[A-Z0-9_]*[A-Z0-9])"/,
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
    assert "OPUS_SERVICE_KEY" in read and "KEEPER_CHANNEL" in read
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

  test "the glossary's directories, compose services and images are the tree's" do
    for dir <- glossary_column("Directory") do
      assert File.dir?(Path.join(@repo_root, dir)),
             "the glossary names #{dir}, which is not a directory"
    end

    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))
    services = compose_services(compose)

    assert Enum.sort(glossary_column("Compose service")) == Enum.sort(Map.keys(services)),
           "the glossary's compose services are not docker-compose.yml's"

    # The images the release workflow builds, each from its Dockerfile.
    built =
      ~r/- image: ([a-z][a-z0-9-]*)\n\s+file: (\S+)/
      |> Regex.scan(File.read!(Path.join(@repo_root, ".github/workflows/docker.yml")),
        capture: :all_but_first
      )
      |> Map.new(fn [image, file] -> {image, file} end)

    for {image, file} <- built do
      assert File.regular?(Path.join(@repo_root, file)),
             "docker.yml builds #{image} from #{file}, which is missing"
    end

    images =
      glossary_column(
        "Binary or image",
        ~r/image `([a-z][a-z0-9-]*)`|`([a-z][a-z0-9-]*)` and `([a-z][a-z0-9-]*)` images/
      )

    assert Enum.sort(Enum.uniq(images)) == Enum.sort(Map.keys(built)),
           "the glossary's images #{inspect(images)} are not the ones docker.yml builds"

    # Every image of ours compose runs is one the workflow publishes, built
    # from the Dockerfile the workflow builds it from.
    for {name, service} <- services,
        image = service.image,
        String.starts_with?(image, "ghcr.io/cyfrworks/") do
      published = image |> String.trim_leading("ghcr.io/cyfrworks/") |> String.split(":") |> hd()

      assert Map.has_key?(built, published),
             "compose's #{name} runs #{image}, which docker.yml does not build"

      if service.dockerfile do
        assert service.dockerfile == built[published],
               "compose builds #{name} from #{service.dockerfile}, docker.yml from #{built[published]}"
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
  @fossil_step "Tier A/B fossil patterns must be absent"

  # A shipped component version is immutable, and this one's README and
  # manifest say the retired name; it changes only in a new version.
  # Exact: the exception must still hold a hit.
  @retired_name_exceptions ["seed/components/formulas/local/list-models/0.6.2/"]

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
    assert "keeper" in directories and "codex" in directories and "grimoire" in directories

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
        cd: @repo_root
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

    excepted? = fn {rel, _} -> String.starts_with?(rel, @retired_name_exceptions) end
    {excepted, stray} = Enum.split_with(hits, excepted?)

    assert stray == [],
           "these lines say the retired name of the athanor: " <>
             Enum.map_join(stray, ", ", fn {rel, n} -> "#{rel}:#{n}" end)

    for prefix <- @retired_name_exceptions do
      assert Enum.any?(excepted, fn {rel, _} -> String.starts_with?(rel, prefix) end),
             "#{prefix} no longer says the retired name; remove its exception"
    end
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

  # ==========================================================================
  # integration-guide's two reference tables
  #
  # These are what an integrator writes their client against, and both had
  # drifted into fiction: the error table listed twelve codes that no
  # producer mints (`auth_expired`, `component_not_found`, a whole `-334xx`
  # signature band) while omitting `-33304 rate_limited` — the one code a
  # client needs to back off — and the public-tools table said `session`
  # "all", which quietly published `session.use`, the tenancy switch.
  #
  # A wrong reference is worse than a missing one: it is followed. So both
  # tables are now derived from the code and checked in both directions.
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
    for provider <- Grimoire.configured_providers(),
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

    # The other direction, which is the one that had gone wrong: the table
    # published `registry`, `aqua` and `component` reads as needing no auth
    # when all three need a credential, so a client written from it got
    # `-33001` on its first call. `auth: :signed_in` is NOT public — it
    # serves a live session, with or without an athanor to work in.
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
  # resolvers it calls read it, is documented in `.env.example`, the file
  # cyfr reads.
  test "every worker variable of cyfr's that the runtime configuration reads is documented in .env.example" do
    read =
      for file <-
            ~w(config/runtime.exs apps/cyfr/lib/cyfr/runtime_config.ex
               apps/cyfr/lib/cyfr/platform/settings/roster.ex),
          [name] <-
            Regex.scan(
              ~r/"(CYFR_OPUS_WORKERS|CYFR_OPUS_[A-Z0-9_]+|CYFR_HOST_API_[A-Z0-9_]+)"/,
              File.read!(Path.join(@repo_root, file)),
              capture: :all_but_first
            ),
          uniq: true,
          do: name

    assert length(read) >= 6, "the scan found only #{inspect(read)}"

    project = documented(File.read!(Path.join(@repo_root, ".env.example")))
    undocumented = Enum.reject(read, &MapSet.member?(project, &1))

    assert undocumented == [],
           "config/runtime.exs reads these worker variables, and .env.example does not " <>
             "document them: #{inspect(undocumented)}"
  end

  # ==========================================================================
  # Where each setting of the worker and the builder is documented
  #
  # Compose hands a service the values its `environment:` names, over
  # anything its own env file sets: the opus service gets its id, its key
  # and the host URL interpolated from the project .env and a fixed bind
  # address and port; the builds service gets its key from .env's
  # CYFR_LOCUS_BUILDS_KEY. So a variable the opus or locus release reads has
  # one place an operator sets it, and the documentation is there alone:
  #
  #   * `.env.example`, for what compose interpolates from the project .env;
  #   * the service's own example (`.env.opus.example`, `.env.locus.example`),
  #     for what its env file can set;
  #   * integration-guide.md's "Running a worker outside Compose", for what
  #     compose fixes and a release run without it is given itself.
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

  # The variables the opus and locus releases read from their operator:
  # config/runtime.exs's OPUS_* (OPUS_ROLE is the keeper's, set on a
  # runner, not an operator's) and Locus.Config's LOCUS_BUILDS_* and
  # LOCUS_BACKENDS_*.
  defp release_variables(runtime, locus_config) do
    opus =
      Regex.scan(~r/"(OPUS_[A-Z0-9_]+)"/, runtime, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&(&1 == "OPUS_ROLE"))

    locus =
      Regex.scan(~r/"(LOCUS_(?:BUILDS|BACKENDS)_[A-Z0-9_]+)"/, locus_config,
        capture: :all_but_first
      )
      |> List.flatten()

    Enum.uniq(opus ++ locus)
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
      ~w(.env.example .env.opus.example .env.locus.example integration-guide.md),
      &{&1, File.read!(Path.join(@repo_root, &1))}
    )
  end

  # Rule 1: every variable a release reads is documented in exactly one
  # home. Answers the violations, `{variable, homes}`.
  defp misplaced(variables, homes) do
    documented_in = %{
      ".env.example" => documented(homes[".env.example"]),
      ".env.opus.example" => documented(homes[".env.opus.example"]),
      ".env.locus.example" => documented(homes[".env.locus.example"]),
      "integration-guide.md" => documented_outside_compose(homes["integration-guide.md"])
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
        String.starts_with?(variable, ["OPUS_", "LOCUS_BUILDS_", "LOCUS_BACKENDS_"]),
        variable not in interpolated,
        do: variable
  end

  defp placement_inputs do
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))

    variables =
      release_variables(
        File.read!(Path.join(@repo_root, "config/runtime.exs")),
        File.read!(Path.join(@repo_root, "apps/locus/lib/locus/config.ex"))
      )

    {compose, compose_services(compose), variables, homes()}
  end

  test "every worker and builder variable is documented where an operator sets it, and only there" do
    {compose, services, variables, homes} = placement_inputs()

    # Guards against the scans quietly matching nothing.
    assert "OPUS_SERVICE_KEY" in variables and "OPUS_BIND" in variables
    assert "LOCUS_BUILDS_KEY" in variables and "LOCUS_BUILDS_MEMORY_BYTES" in variables
    assert "LOCUS_BACKENDS_KEY" in variables and "LOCUS_BACKENDS_MEMORY_BYTES" in variables
    assert length(variables) >= 27, "the scan found only #{inspect(variables)}"
    assert services["opus"].env_files == [".env.opus"]
    assert "OPUS_BIND" in services["opus"].environment
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
    planted = plant.(".env.opus.example", "# OPUS_SERVICE_KEY=")

    assert {"OPUS_SERVICE_KEY", [".env.example", ".env.opus.example"]} in misplaced(
             variables,
             planted
           )

    assert {".env.opus.example", "OPUS_SERVICE_KEY"} in overridden(services, planted)

    # A fixed value documented in the project .env: there twice, and read
    # from .env by nothing.
    planted = plant.(".env.example", "# OPUS_BIND=0.0.0.0")

    assert {"OPUS_BIND", [".env.example", "integration-guide.md"]} in misplaced(
             variables,
             planted
           )

    assert "OPUS_BIND" in stranded(compose, planted)

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

    # A setting documented nowhere.
    unplanted =
      Map.update!(homes, ".env.opus.example", &String.replace(&1, "# OPUS_POOL_SIZE=", "#"))

    assert {"OPUS_POOL_SIZE", []} in misplaced(variables, unplanted)

    # A guide section that loses its table documents nothing.
    renamed =
      Map.update!(
        homes,
        "integration-guide.md",
        &String.replace(&1, @outside_compose, "Elsewhere")
      )

    assert {"OPUS_PORT", []} in misplaced(variables, renamed)
  end

  # Compose reads the variables it interpolates from the project .env, so
  # each is documented in an env example an operator copies: the service
  # settings where they are read, and the containers' own limits, which no
  # release reads, in `.env.example` beside the settings they hold.
  test "every variable docker-compose.yml interpolates is documented in an env example" do
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
          into: MapSet.new(),
          do: name

    undocumented = Enum.reject(interpolated, &MapSet.member?(documented, &1))

    assert undocumented == [],
           "docker-compose.yml reads these from the project .env, and no env example " <>
             "documents them: #{inspect(undocumented)}"

    # The containers' limits are compose's alone: documented where compose
    # reads them, and read by no release.
    project = File.read!(Path.join(@repo_root, ".env.example"))
    runtime = File.read!(Path.join(@repo_root, "config/runtime.exs"))
    locus_runtime = File.read!(Path.join(@repo_root, "apps/locus/lib/locus/config.ex"))

    for limit <- Enum.filter(interpolated, &String.ends_with?(&1, "_LIMIT")) do
      assert project =~ ~r/^# #{limit}=/m, "#{limit} is not documented in .env.example"
      refute runtime =~ limit, "config/runtime.exs reads the compose-only #{limit}"
      refute locus_runtime =~ limit, "Locus.Config reads the compose-only #{limit}"
    end
  end

  # The builds service is two variables, read by one resolver
  # (`Cyfr.RuntimeConfig.resolve_locus_builds/1`), documented where an
  # operator sets them.
  test "the builds service's variables are documented in .env.example and the integration guide" do
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
    guide = File.read!(Path.join(@repo_root, "integration-guide.md"))

    for name <- read do
      assert project =~ ~r/^# #{name}=/m, "#{name} is not documented in .env.example"
      assert guide =~ "`#{name}`", "#{name} is not in integration-guide.md's reference"
    end

    assert project =~ "# CYFR_LOCUS_BUILDS_URL=http://locus-builds:4100"
  end

  # The backends service is four variables of the control plane's, read by
  # `config/runtime.exs` (its two periods through the platform settings
  # roster), documented where an operator sets them.
  test "the backends service's variables are documented in .env.example and the integration guide" do
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
    guide = File.read!(Path.join(@repo_root, "integration-guide.md"))

    for name <- read do
      assert project =~ ~r/^# #{name}=/m, "#{name} is not documented in .env.example"
      assert guide =~ "`#{name}`", "#{name} is not in integration-guide.md's reference"
    end

    assert project =~ "# CYFR_LOCUS_BACKENDS_URL=http://locus-backends:4101"
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
  # engine's error types (`Opus.Egress`), and the fetch interface's error
  # list in the component guide names every one.
  test "component-guide's fetch error types name every type a refused pin reaches the guest as" do
    answered =
      @repo_root
      |> Path.join("apps/opus/lib/opus/egress.ex")
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

  test "the guides' tincture-block keys are ones the code actually reads" do
    # Documented tincture keys must match validator and consumer support.
    documented_only = ~w(sandbox)

    for guide <- ~w(component-guide.md tincture-guide.md), key <- documented_only do
      source = File.read!(Path.join(@repo_root, guide))

      refute source =~ "`#{key}` |",
             "#{guide} documents tincture.#{key} as a field, but nothing reads it"
    end
  end

  # ==========================================================================
  # Every variable the releases read has one home, and every documented
  # name is read
  #
  # The rules above place the worker and builder variables; this holds the
  # whole set, every `CYFR_*`, `OPUS_*`, `LOCUS_*` and `KEEPER_*` name the
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
    # (`Opus.Settings.runner_environment/1`), and the keeper adds the
    # control and relay descriptors; the test build's direct keeper names
    # a relay socket in the descriptor's place.
    "OPUS_ROLE" => :worker_service,
    "OPUS_RUNNER_ID" => :worker_service,
    "OPUS_BOOT_ID" => :worker_service,
    "OPUS_CONTROL_FD" => :keeper,
    "OPUS_RELAY_FD" => :keeper,
    "OPUS_RELAY_SOCKET" => :keeper,
    # Retired: `Opus.Settings` reads it only to refuse a service that sets it.
    "OPUS_KEEPER" => :retired
  }

  # A name two releases read, each from its own env file, is documented in
  # each: cyfr reads it from .env, the opus service from .env.opus.
  @read_by_two %{"CYFR_LOG_LEVEL" => [".env.example", ".env.opus.example"]}

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
      |> Enum.reject(fn {name, found} -> Map.get(@read_by_two, name) == found end)

    assert violations == [],
           """
           Each of these is read by a release and documented in no home or in \
           more than one ({variable, homes}):

           #{inspect(violations)}
           """

    for {name, examples} <- @read_by_two do
      assert name in read, "#{name} is on the read-by-two roster, and nothing reads it"
      assert {name, examples} in misplaced([name], homes)
    end
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
      for example <- ~w(.env.example .env.opus.example .env.locus.example),
          name <- documented(File.read!(Path.join(@repo_root, example))),
          not MapSet.member?(read, name),
          do: {example, name}

    assert unread == [],
           "these examples document names no release reads and compose does not " <>
             "interpolate: #{inspect(unread)}"
  end

  # ==========================================================================
  # integration-guide's scope, key-type, vault and consent-walk tables
  # ==========================================================================

  # The rows of the first table under `heading`, up to the next heading,
  # each as its trimmed cells.
  defp guide_table(heading) do
    guide = File.read!(@integration_guide)

    [_, section] =
      Regex.run(~r/^#{Regex.escape(heading)}\n(.*?)(?=^#)/ms, guide) ||
        flunk("integration-guide.md has no section #{inspect(heading)}")

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
      Enum.find_value(Grimoire.configured_providers(), fn provider ->
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
end
