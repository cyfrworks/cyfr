# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ContextSwapTest do
  @moduledoc """
  Checks context changes use Sanctum.Context.refocus/2 so membership,
  archive state, and operator access are validated.

  The chokepoint is `Sanctum.Context.refocus/2` (focus for a person,
  archive-checked crossing for the system plane). This pins that the
  domains that narrow onto other athanors go through it: the agent
  harness, the two person-surface MCP tools, the agents page, and the
  Sanctum tree itself. The allowlist names the surviving raw swaps by
  file WITH their expected count, so a new swap beside a rostered one
  still fails — each row says why its file may keep the shape.

  `Sanctum.Provisioning`'s internal mint context and the test tree are
  out of scope: the first constructs a context for an athanor it is
  creating, and tests may stage whatever shape they assert on.
  """

  use ExUnit.Case, async: true

  @scanned [
    "apps/cyfr/lib/aqua",
    "apps/cyfr/lib/prism_web",
    "apps/sanctum/lib"
  ]

  # Raw swaps that stay, by file and exact count.
  @allowlisted %{
    # focus/2's two admitting arms and refocus/2's system arm.
    "apps/sanctum/lib/sanctum/context.ex" => 3,
    # The tenancy-resolver override exists only when compiled with
    # `:allow_tenancy_resolver_override` (test builds); production
    # compiles the branch out entirely.
    "apps/sanctum/lib/sanctum/tenancy.ex" => 1,
    # `resolve/3` narrows through `focus/2`; the one swap left is its
    # open of an ARCHIVED athanor for `get`/`unarchive`, hand-built under
    # the same two admissions (membership, or the operator's audited open)
    # because `focus/2` rightly refuses an archived athanor.
    "apps/sanctum/lib/sanctum/providers/athanor.ex" => 1
  }

  @pattern ~r/%\{\s*[\w.]+\s*\|\s*athanor_id:/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp sources do
    Enum.flat_map(@scanned, fn path ->
      full = Path.join(root(), path)

      if File.dir?(full),
        do: Prima.Test.SourceTree.files!(Path.join(full, "**/*.ex")),
        else: [full]
    end)
  end

  test "athanor narrowing goes through Sanctum.Context.refocus/2" do
    hits =
      for path <- sources(),
          rel = Path.relative_to(path, root()),
          {line, n} <-
            path
            |> File.read!()
            |> Prima.Test.CodeLines.code_lines(),
          String.match?(line, @pattern) do
        {rel, "#{rel}:#{n}: #{String.trim(line)}"}
      end

    offenders =
      for {rel, formatted} <- hits, not Map.has_key?(@allowlisted, rel), do: formatted

    assert offenders == [],
           """
           These narrow a context onto another athanor with a raw struct
           update instead of `Sanctum.Context.refocus/2`:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}

           The raw update skips membership, the archived refusal and the
           operator audit. Go through the chokepoint — or, for a genuinely
           new kind of exception, add an allowlist row here with the reason.
           """

    counts = hits |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

    for {rel, expected} <- @allowlisted do
      found = Map.get(counts, rel, 0)

      assert found == expected,
             """
             `#{rel}` carries #{found} raw athanor swaps where the roster
             expects #{expected}. A new one goes through
             `Sanctum.Context.refocus/2`; a removed one shrinks the count
             here so the roster stays honest.
             """
    end
  end
end
