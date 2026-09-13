# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.EstablishBoundaryTest do
  @moduledoc """
  `Sanctum.Caller.establish/2` is the only builder of an authenticated
  context from a credential. Mechanically: every code line that builds a
  context with `authenticated: true` is one of the enumerated sites, and
  the credential recipes — a session load, an API key's context, a
  tincture token's verification — are called from `Sanctum.Caller` alone.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # A build site spells the keyword on a line of its own; a pattern match
  # (`%Sanctum.Context{authenticated: true}`) does not.
  @build_line ~r/^\s*authenticated: true,?\s*$/

  # Every file that builds an authenticated context, with its site count
  # and what each site is.
  @sites %{
    # The recipes `establish/2` runs in place: a tincture token and a
    # webhook row.
    "apps/cyfr/lib/sanctum/caller.ex" => 2,
    # `Session.load/2`, the session recipe `establish/2` calls.
    "apps/cyfr/lib/sanctum/session.ex" => 1,
    # `ApiKey.context_from_metadata/1`, the key recipe `establish/2` calls.
    "apps/cyfr/lib/sanctum/api_key.ex" => 1,
    # `Context.internal/1`: the server's own tasks; no credential.
    "apps/cyfr/lib/sanctum/context.ex" => 1,
    # The context a tincture invocation runs under, derived from an
    # already established caller's, or the public identity.
    "apps/cyfr/lib/sanctum/sanctum.ex" => 1,
    # `Provisioning`'s person context: the server filling an admitted
    # person's estate with their pull credential; no credential of its own.
    "apps/cyfr/lib/sanctum/provisioning.ex" => 1,
    # `Tenancy.continuation/2`: the person-shaped context a recovered
    # turn continues under, rebuilt from the turn's rows and refused when
    # the person is denied, unseated or the estate archived.
    "apps/cyfr/lib/sanctum/tenancy.ex" => 1,
    # The test fixture.
    "apps/cyfr/lib/sanctum/test_context.ex" => 1
  }

  # The credential recipes, callable from `Sanctum.Caller` only.
  @recipes [
    ~r/\bSession\.load\(/,
    ~r/\bApiKey\.(?:validate|context_from_metadata)\(/,
    ~r/\bTinctureAuth\.verify_access_token\(/
  ]
  @caller "apps/cyfr/lib/sanctum/caller.ex"

  defp lib_files do
    for dir <- ~w(apps/cyfr/lib apps/opus/lib apps/locus/lib),
        file <- Path.wildcard(Path.join([@root, dir, "**/*.ex"])),
        do:
          {Path.relative_to(file, @root),
           Cyfr.Test.CodeLines.lines(Cyfr.Test.SourceTree.read(file))}
  end

  test "an authenticated context is built only at the enumerated sites" do
    found =
      for {rel, lines} <- lib_files(),
          count = Enum.count(lines, &Regex.match?(@build_line, &1)),
          count > 0,
          into: %{},
          do: {rel, count}

    new_sites = for {rel, count} <- found, count > Map.get(@sites, rel, 0), do: rel

    assert new_sites == [],
           """
           A context is built with `authenticated: true` outside the enumerated sites:

           #{Enum.map_join(Enum.sort(new_sites), "\n", &"  #{&1}")}

           A credential becomes a context through `Sanctum.Caller.establish/2`
           alone. A site that is not a credential (the server's own work)
           belongs in this test's roster, with a comment saying what it is.
           """

    stale = for {rel, count} <- @sites, Map.get(found, rel, 0) != count, do: rel

    assert stale == [],
           "stale roster entries (site count changed — update the roster and its " <>
             "comments): #{inspect(Enum.sort(stale))}"
  end

  test "the credential recipes are called from Sanctum.Caller alone" do
    reaches =
      for {rel, lines} <- lib_files(),
          rel != @caller,
          line <- lines,
          Enum.any?(@recipes, &Regex.match?(&1, line)),
          do: "#{rel}: #{String.trim(line)}"

    assert reaches == [],
           "a credential recipe is called outside Sanctum.Caller:\n" <>
             Enum.join(reaches, "\n")
  end
end
