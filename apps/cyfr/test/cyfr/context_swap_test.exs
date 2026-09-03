# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ContextSwapTest do
  @moduledoc """
  A raw `%{ctx | athanor_id: …}` update is a cross-tenant narrowing with
  none of `Sanctum.Context.focus/2`'s checks: no membership, no archived
  refusal, no operator audit. Each site that carried one was individually
  safe by construction — which is exactly how the next copy stops being.

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
    "apps/cyfr/lib/emissary/mcp/conversation_tool.ex",
    "apps/cyfr/lib/emissary/mcp/notes_tool.ex",
    "apps/cyfr/lib/prism_web/live/agents_live.ex",
    "apps/cyfr/lib/sanctum"
  ]

  # Raw swaps that stay, by file and exact count.
  @allowlisted %{
    # The chokepoint's own body: `focus/2`'s two admitting arms,
    # `refocus/2`'s system arm, and one line of doc prose naming the
    # banned shape.
    "apps/cyfr/lib/sanctum/context.ex" => 4,
    # The tenancy-resolver override exists only when compiled with
    # `:allow_tenancy_resolver_override` (test builds); production
    # compiles the branch out entirely.
    "apps/cyfr/lib/sanctum/tenancy.ex" => 1,
    # `resolve/3`: the member branch swaps after its own membership
    # check, and the operator branch hand-builds the focused shape with
    # the same audit event `focus/2` emits — because `focus/2` rightly
    # refuses an archived athanor, and `unarchive`/`get` must still be
    # able to name one.
    "apps/cyfr/lib/sanctum/mcp/athanor_tool.ex" => 2
  }

  @pattern ~r/%\{\s*[\w.]+\s*\|\s*athanor_id:/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp sources do
    Enum.flat_map(@scanned, fn path ->
      full = Path.join(root(), path)

      if File.dir?(full),
        do: Path.wildcard(Path.join(full, "**/*.ex")),
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
            |> String.split("\n")
            |> Enum.with_index(1),
          # Comment lines are prose, not reaches — the modules document the
          # banned shape by name.
          not String.match?(line, ~r/^\s*#/),
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
