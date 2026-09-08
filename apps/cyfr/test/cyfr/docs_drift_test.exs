# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.DocsDriftTest do
  @moduledoc """
  CLAUDE.md is the operating manual every session reads before touching
  the tree; a storage root it does not name is a root nobody defends.
  This binds its storage-tree sentence to the layout SSOT the same way
  the drift guards bind the protocol literals.

  ## One of these guards is local-only, on purpose

  `CLAUDE.md` is gitignored — it is the operator's own agent contract, not
  repo content — so a fresh checkout does not have it and **CI never runs
  that first test** (`:requires_local_docs`, excluded by `test_helper.exs`
  when the file is absent). Do not mistake it for CI protection: it
  catches drift on the machine that owns the file, and nowhere else.

  The other four read tracked files (README and the three guides) and do
  run everywhere. Before this tag the CLAUDE.md test was an unguarded
  `File.read!`, so a clean clone raised `File.Error` and the whole module
  — including those four — protected nothing.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @claude_md Path.join(@repo_root, "CLAUDE.md")
  @readme Path.join(@repo_root, "README.md")
  @upgrading Path.join(@repo_root, "UPGRADING.md")

  @tag :requires_local_docs
  test "CLAUDE.md's storage tree names every tenant root and global prefix" do
    doc = File.read!(@claude_md)

    # The tenant roots appear in one brace group after the athanor id.
    for root <- Arca.Storage.tenant_roots() do
      assert doc =~ root,
             "tenant root #{root} is missing from CLAUDE.md's storage tree"
    end

    # The global server roots ride in a `data/{...}` group of their own.
    for prefix <- Arca.Storage.global_prefixes() do
      assert doc =~ prefix,
             "global prefix #{prefix} is missing from CLAUDE.md's storage tree"
    end
  end

  test "UPGRADING's roster of the aqua tool's writes and reads is the tool's own" do
    # The note that says which `aqua` verbs need a person's session, and
    # which stay open to a key, is read by operators writing scripts; it
    # is bound to the tool's enum and consent classes so it cannot name a
    # verb the tool lost or miss one it gained.
    doc = File.read!(@upgrading)

    [section] =
      Regex.run(~r/### Writes to the AQUA tree are a person's act\n(.*?)\n### /s, doc,
        capture: :all_but_first
      )

    actions = Compendium.MCP.AquaTool.definition().annotations.actions

    {writes, reads} =
      actions
      |> Map.keys()
      |> Enum.split_with(&(actions[&1][:consent] == :interactive))

    [write_sentence] =
      Regex.run(~r/Every write on the `aqua` tool — (.*?) — now requires/s, section,
        capture: :all_but_first
      )

    [read_sentence] =
      Regex.run(~r/the reads \((.*?)\) are unchanged/s, section, capture: :all_but_first)

    assert Enum.sort(backticked(write_sentence)) == Enum.sort(writes)
    assert Enum.sort(backticked(read_sentence)) == Enum.sort(reads)
  end

  defp backticked(text) do
    ~r/`([a-z_]+)`/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  test "README's storage tree names every tenant root and global prefix" do
    doc = File.read!(@readme)

    # The README draws the tree with a trailing slash per directory —
    # matched with the slash so "metadata" prose can't stand in for `meta/`.
    for root <- Arca.Storage.tenant_roots() ++ Arca.Storage.global_prefixes() do
      assert doc =~ root <> "/",
             "root #{root}/ is missing from README's storage tree"
    end
  end

  # The three operator guides are compile-embedded reference material every
  # athanor is given (@external_resource into the aqua tool) — they drift
  # exactly like README did, and only CLAUDE.md/README were pinned here.
  # component-guide's storage tree shipped without meta/ for that reason.
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

  test "the guides' tincture-block keys are ones the code actually reads" do
    # The truth roster: what the validator shape-checks plus what the
    # registry/controller consume (entry, icon, tagline, public, build,
    # window, connect, media). A key documented that nothing reads — the
    # old `sandbox` row — teaches authors a knob that does not exist.
    documented_only = ~w(sandbox)

    for guide <- ~w(component-guide.md tincture-guide.md), key <- documented_only do
      source = File.read!(Path.join(@repo_root, guide))

      refute source =~ "`#{key}` |",
             "#{guide} documents tincture.#{key} as a field, but nothing reads it"
    end
  end
end
