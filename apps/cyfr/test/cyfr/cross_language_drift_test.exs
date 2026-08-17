# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.CrossLanguageDriftTest do
  @moduledoc """
  Mechanical drift guards for logic implemented more than once across
  languages. The suites (mix / go test / node) run in mutually exclusive
  path-filtered CI workflows, so nothing else can notice when a port and
  its original stop agreeing. Companion to
  `Emissary.MCP.ClientProtocolDriftTest`, which pins the protocol revision.

  Style follows `Cyfr.IngressInventoryTest`: read the sources, compare
  literals. Coarse on purpose — a failure here means "the port drifted, go
  look", never a behavioural assertion.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  test "the Go ref grammar matches Sanctum.ComponentRef" do
    elixir = read!("apps/cyfr/lib/sanctum/component_ref.ex")
    go = read!("apps/codex/internal/ref/ref.go")

    # These three are byte-identical expressions on both sides; the name
    # rule is structured differently per language (Go folds the length cap
    # into the regex) and is covered by each side's own tests.
    shared = [
      "^[a-z0-9]+(-[a-z0-9]+)*$",
      "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$",
      "^\\d+\\.\\d+\\.\\d+(-[a-zA-Z0-9.-]+)?(\\+[a-zA-Z0-9.-]+)?$"
    ]

    for expr <- shared do
      assert String.contains?(elixir, expr),
             "expression missing from component_ref.ex: #{expr}"

      assert String.contains?(go, expr),
             "expression missing from ref.go: #{expr}"
    end
  end
end
