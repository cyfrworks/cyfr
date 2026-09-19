# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DocsDriftTest do
  @moduledoc """
  Checks documented storage roots and manifest fields against their
  runtime definitions.

  README and guide checks use tracked files and run in every checkout.
  """
  use ExUnit.Case, async: true

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

    for key <- Compendium.Manifest.known_keys() do
      assert source =~ "| `#{key}` |",
             "manifest key `#{key}` (Compendium.Manifest.known_keys/0) is missing " <>
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

      assert Emissary.MCP.Message.error_code(atom) == code,
             "integration-guide documents #{code} `#{name}`, which " <>
               "Emissary.MCP.Message does not define under that name — a client " <>
               "branching on it waits for a code that never arrives"
    end
  end

  test "every code a client could receive is in the guide's table" do
    documented = guide_error_codes() |> Map.keys() |> MapSet.new()

    # `request_cancelled` is recorded, never sent: by the time it exists the
    # caller has closed the stream. It is the one code with no reader.
    internal = [:request_cancelled]

    missing =
      for {name, code} <- Emissary.MCP.Message.cyfr_error_codes(),
          name not in internal,
          not MapSet.member?(documented, code),
          do: "#{code} #{name}"

    assert missing == [],
           "these codes reach clients but integration-guide's error table omits " <>
             "them: #{inspect(Enum.sort(missing))}"
  end

  # Every action a provider annotates `auth: :anonymous` — the actions that
  # answer without a session, which is exactly what the table claims to list.
  defp anonymous_actions do
    for provider <- Cyfr.Ops.Catalog.available_providers(),
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

  # The worker vocabulary `config/runtime.exs` reads is documented where an
  # operator sets it: cyfr's side in `.env.example`, the worker's own in
  # `.env.opus.example`. `OPUS_ROLE` is the keeper's, not an operator's.
  test "every worker variable runtime.exs reads is documented in an env example" do
    read =
      @repo_root
      |> Path.join("config/runtime.exs")
      |> File.read!()
      |> then(&Regex.scan(~r/"((?:CYFR_WORKER|CYFR_HOST_API|OPUS)_[A-Z0-9_]+)"/, &1))
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "OPUS_ROLE"))

    assert length(read) >= 12, "the scan found only #{inspect(read)}"

    documented =
      for example <- ~w(.env.example .env.opus.example),
          [_, name] <-
            Regex.scan(
              ~r/^#?\s*((?:CYFR|OPUS)_[A-Z0-9_]+)=/m,
              File.read!(Path.join(@repo_root, example))
            ),
          into: MapSet.new(),
          do: name

    undocumented = Enum.reject(read, &MapSet.member?(documented, &1))

    assert undocumented == [],
           "config/runtime.exs reads these worker variables, and neither .env.example nor " <>
             ".env.opus.example documents them: #{inspect(undocumented)}"
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

  # What `describe` may answer, as `Cyfr.Models` reads it, is what the
  # guide documents for a catalyst author.
  test "every field Cyfr.Models reads from describe is in the component guide" do
    read =
      @repo_root
      |> Path.join("apps/cyfr/lib/cyfr/models.ex")
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

  test "the guides' tincture-block keys are ones the code actually reads" do
    # Documented tincture keys must match validator and consumer support.
    documented_only = ~w(sandbox)

    for guide <- ~w(component-guide.md tincture-guide.md), key <- documented_only do
      source = File.read!(Path.join(@repo_root, guide))

      refute source =~ "`#{key}` |",
             "#{guide} documents tincture.#{key} as a field, but nothing reads it"
    end
  end
end
