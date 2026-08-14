# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.AquaActionsConsistencyTest do
  # `Prism.AquaActions` (Elixir, drives the Prism console) is a port of
  # `apps/porta/src-ui/src/harness/aqua-actions-parser.ts` (drives the Porta
  # PWA). The two frontends have different views, so surface-specific actions
  # legitimately differ — Prism has execution/activity focus, Porta has tincture
  # open/close. What must NOT drift is the shared protocol core: the primitives
  # an agent relies on regardless of which surface renders it. If one parser
  # drops `ui.request_approval` or `ui.navigate`, the agent silently breaks on
  # that surface. Nothing guarded this pair; its sibling
  # (aqua_rust_consistency_test) had already caught real drift.
  use ExUnit.Case, async: true

  @parser_ts Path.join([
               __DIR__,
               "../../../../apps/porta/src-ui/src/harness/aqua-actions-parser.ts"
             ])

  # Protocol primitives both surfaces must interpret identically.
  @shared_core ~w(
    ui.navigate
    ui.overlay.open
    ui.overlay.close
    ui.overlay.focus_input
    ui.copy_clipboard
    ui.request_approval
    ui.tincture.focus
  )

  defp elixir_kinds do
    ~r/validate_kind\("([^"]+)"/
    |> Regex.scan(File.read!(Path.join(__DIR__, "../../lib/prism/aqua_actions.ex")))
    |> Enum.map(&List.last/1)
    |> MapSet.new()
  end

  defp ts_kinds do
    assert_ts_present()

    ~r/case\s+"(ui\.[a-z._]+)":/
    |> Regex.scan(File.read!(@parser_ts))
    |> Enum.map(&List.last/1)
    |> MapSet.new()
  end

  defp assert_ts_present do
    assert File.exists?(@parser_ts),
           "aqua-actions-parser.ts not found at #{@parser_ts} — update the path"
  end

  test "the Elixir parser handles every shared-core protocol kind" do
    kinds = elixir_kinds()

    for core <- @shared_core do
      assert MapSet.member?(kinds, core),
             "Prism.AquaActions dropped shared-core kind #{core}"
    end
  end

  test "the TypeScript parser handles every shared-core protocol kind" do
    kinds = ts_kinds()

    for core <- @shared_core do
      assert MapSet.member?(kinds, core),
             "aqua-actions-parser.ts dropped shared-core kind #{core}"
    end
  end

  test "the two parsers agree on the shared protocol core" do
    # Both must handle exactly the shared core within it — a core primitive
    # present in one but not the other is the drift that breaks an agent on one
    # surface. Surface-specific actions (focus/tincture management) are excluded.
    elixir_core = MapSet.intersection(elixir_kinds(), MapSet.new(@shared_core))
    ts_core = MapSet.intersection(ts_kinds(), MapSet.new(@shared_core))

    assert elixir_core == ts_core
  end
end
